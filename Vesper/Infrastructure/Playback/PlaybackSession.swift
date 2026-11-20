import AVFoundation
import AudioToolbox
@preconcurrency import Photos
@preconcurrency import AVKit
import MediaPlayer
import Combine
import SwiftUI
import PlaybackContracts
import VesperAetherBridge
import VesperVLCBridge
import UIKit

/// A single app-owned session. Tabs and player presentation never own or reset
/// the decoder. PlaybackCore owns engine scheduling behind the existing UI API.
@MainActor
final class PlaybackSession: NSObject, ObservableObject, @preconcurrency AVPictureInPictureControllerDelegate {
    @Published private(set) var currentEngine = PlaybackPreferences.preferredEngine
    @Published private(set) var currentDecoder = PlaybackPreferences.preferredDecoder
    @Published private(set) var history: [PlaybackHistoryEntry] = []
    private struct PlayedEdit {
        let id: UUID
        let played: Bool
        var syncedAt: Date?
    }
    private struct EmbyRecordWrite {
        let id: UUID
        let task: Task<Void, Error>
    }
    @Published private var playedEdits: [MediaID: PlayedEdit] = [:]
    private var recordWrites: [MediaID: EmbyRecordWrite] = [:]
    private var manuallyUnplayedCurrentItem: MediaID?
    private var lastHistorySave = Date.distantPast
    @Published private(set) var currentItem: MediaItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var videoView: UIView?
    @Published var isPresented = false
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var fillsScreen = false
    @Published private(set) var bufferedTime: TimeInterval = 0
    @Published private(set) var isSeeking = false
    @Published private(set) var audioTracks: [PlaybackTrack] = []
    @Published private(set) var subtitleTracks: [PlaybackTrack] = []
    @Published private(set) var selectedSubtitleID: Int32?
    @Published private(set) var subtitleText = ""
    @Published private(set) var subtitleImage: UIImage?
    @Published private(set) var isMuted = false
    @Published private(set) var isPictureInPicturePossible = false
    @Published private(set) var isPictureInPictureActive = false
    @Published var playbackNotice: String?
    private var pipController: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private var pipConfigurationObservation: NSKeyValueObservation?
    private var preferencesObservation: AnyCancellable?
    private var appliedBackgroundPolicy = ""
    private var restorePiPCompletion: ((Bool) -> Void)?
    private var restoringPiP = false
    private var pendingSeek: (time: TimeInterval, resume: Bool)?
    private var seekInFlight = false
    private var seekLanding: (time: Double, deadline: Date)?
    private var appIsInBackground = false
    private var appIsInactive = false
    private var progressRestored = false
    private var lastProgressSave = Date.distantPast
    private let progressStorageKey = "player.savedProgress"
    private let durationStorageKey = "player.savedDurations"
    @Published private(set) var savedProgressRevision = 0
    private var suppressedProgressID: MediaID?

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "player.history.v1"),
           let entries = try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data) {
            history = entries
        }
        core.onChange = { [weak self] in self?.syncCoreState() }
        core.log = { [weak self] in self?.log($0) }
        core.onEngineFailure = { [weak self] message in
            guard let self, let requested = self.requestedDecoder else { return }
            self.requestedDecoder = nil
            self.playbackNotice = "切换至\(requested.title)失败：\(message)。正在尝试备用播放引擎。"
        }
        core.restoreUI = { [weak self] completion in
            guard let self else { completion(false); return }
            self.restoringPiP = true
            if self.isPresented { completion(true) }
            else { self.restorePiPCompletion = completion; self.isPresented = true }
        }
        refreshPlaybackPreferences()
        preferencesObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.appliedBackgroundPolicy != self.backgroundPolicyID else { return }
                    self.refreshPlaybackPreferences()
                }
            }
        let savedRate = UserDefaults.standard.float(forKey: "player.playbackRate")
        if [Float(0.5), 0.75, 1, 1.25, 1.5, 2].contains(savedRate) { playbackRate = savedRate }
    }

    private let core = PlaybackCore()
    private var trackIDs: [String: Int32] = [:]
    private var nextTrackID: Int32 = 1
    private var previouslyActivePiP = false
    private var requestedDecoder: PlaybackDecoder?
    private var resource: ResolvedPlaybackResource?
    private var embySession: EmbyPlaybackSession?
    private var request: Task<Void, Never>?
    private var generation = UUID()
    @Published private(set) var queue: [MediaItem] = []
    private var source: MediaSource?
    private var externalFile: IncomingVideo?

    var queueSource: MediaSource? { source }

    var hasNext: Bool {
        guard let currentItem, let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return false }
        return index + 1 < queue.count
    }
    var canControl: Bool { core.driver != nil && !core.isTransitioning && errorMessage == nil }
    var canSeek: Bool { canControl && duration > 0 && core.snapshot.seekable }

    func play(_ item: MediaItem, in source: MediaSource, queue: [MediaItem],
              audio: EmbyMediaStreamDetails? = nil, subtitle: EmbyMediaStreamDetails? = nil,
              streams: [EmbyMediaStreamDetails] = []) {
        recordPlaybackHistory()
        externalFile = nil
        self.queue = queue
        self.source = source
        isPresented = true
        load(item, source: source, initialAudio: trackPreference(audio, streams: streams),
             initialSubtitle: trackPreference(subtitle, streams: streams))
    }

    private func trackPreference(_ stream: EmbyMediaStreamDetails?, streams: [EmbyMediaStreamDetails]) -> EngineTrack? {
        guard let stream else { return nil }
        let siblings = streams.filter { $0.type == stream.type }
        let ordinal = siblings.firstIndex(where: { $0.id == stream.id }) ?? 0
        // This is a preference hint, never an engine-local track ID.
        return EngineTrack(id: "emby-preference:\(ordinal)", name: stream.title ?? stream.displayTitle ?? "",
                           language: stream.language, codec: stream.codec)
    }

    func playExternal(_ file: IncomingVideo) {
        recordPlaybackHistory()
        externalFile = file
        source = nil
        queue = []
        let item = MediaItem(id: MediaID(sourceID: file.id, localID: file.name),
                             title: file.name, resource: nil)
        isPresented = true
        load(item, source: nil)
    }

    func setCurrentDecoder(_ decoder: PlaybackDecoder) {
        guard decoder != currentDecoder, let item = currentItem else { return }
        requestedDecoder = decoder
        let position = currentTime
        let playing = isPlaying
        let rate = playbackRate
        log("切换解码方式：\(decoder.rawValue)，位置=\(position)，继续播放=\(playing)")
        load(item, source: source, engine: currentEngine, decoder: decoder, position: position, resume: playing, rate: rate)
    }

    func setCurrentEngine(_ engine: PlaybackEngine) {
        guard engine != currentEngine, let item = currentItem else { return }
        load(item, source: source, engine: engine, decoder: currentDecoder,
             position: currentTime, resume: isPlaying, rate: playbackRate)
    }

    private func load(_ item: MediaItem, source: MediaSource?, engine: PlaybackEngine? = nil, decoder: PlaybackDecoder? = nil,
                      position: Double? = nil, resume: Bool = true, rate: Float? = nil,
                      initialAudio: EngineTrack? = nil, initialSubtitle: EngineTrack? = nil) {
        request?.cancel()
        generation = UUID()
        let token = generation
        let previousState = core.snapshot
        let carriesSelection = currentItem?.id == item.id && position != nil
        let previousAudio = carriesSelection ? previousState.audio.first(where: { $0.selected }) : initialAudio
        let previousSubtitle = carriesSelection ? previousState.subtitles.first(where: { $0.selected }) : initialSubtitle
        saveProgress()
        recordPlaybackHistory()
        tearDownPlayer()
        lastHistorySave = .distantPast
        if !carriesSelection { manuallyUnplayedCurrentItem = nil }
        progressRestored = position != nil
        currentEngine = engine ?? PlaybackPreferences.preferredEngine
        currentDecoder = decoder ?? PlaybackPreferences.preferredDecoder
        suppressedProgressID = nil
        currentItem = item
        currentTime = 0
        duration = 0
        errorMessage = nil
        isLoading = true
        let savedRate = UserDefaults.standard.float(forKey: "player.playbackRate")
        playbackRate = [Float(0.5), 0.75, 1, 1.25, 1.5, 2].contains(savedRate) ? savedRate : 1
        if let rate { playbackRate = rate }
        let selectedEngine = currentEngine
        let selectedDecoder = currentDecoder
        let external = externalFile
        request = Task { [weak self] in
            do {
                let resolved: ResolvedPlaybackResource
                if let external {
                    resolved = ResolvedPlaybackResource(url: external.url, externalAccess: external.access)
                } else if let source {
                    resolved = try await PlaybackResourceResolver().resolve(item, source: source, position: position ?? 0)
                } else {
                    throw PlaybackFailure.missingFile
                }
                guard let self, !Task.isCancelled, self.generation == token else {
                    resolved.release()
                    return
                }
                self.resource = resolved
                self.progressRestored = true
                if let source, source.kind == .emby, let playSessionID = resolved.embyPlaySessionID {
                    let session = EmbyPlaybackSession(source: source, item: item, playSessionID: playSessionID,
                                                       mediaSourceID: resolved.embyMediaSourceID ?? item.embyMediaSourceID ?? "")
                    self.embySession = session
                }
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                self.refreshPlaybackPreferences()
                var configuration = self.engineConfiguration
                configuration.decoder = selectedDecoder == .software ? .software : .hardware
                let savedLocalPosition = source?.kind == .emby ? 0 : (self.savedProgress(for: item))
                configuration.position = position ?? (PlaybackPreferences.remembersProgress
                    ? max(savedLocalPosition, resolved.resumePosition ?? 0) : 0)
                configuration.autoplay = resume
                configuration.requestHeaders = resolved.headers
                configuration.externalSubtitles = resolved.externalSubtitles
                try await self.core.load(resolved.url, preferred: selectedEngine == .aether ? .aether : .vlc,
                                         configuration: configuration, audio: previousAudio, subtitle: previousSubtitle,
                                         server: self.embySession)
                guard !Task.isCancelled, self.generation == token else { return }
                self.syncCoreState()
                if let requested = self.requestedDecoder {
                    self.requestedDecoder = nil
                    if let actual = self.core.snapshot.actualDecoder,
                       (actual == .software) != (requested == .software) {
                        self.playbackNotice = "此视频不支持所选的\(requested.title)，已使用可用的解码方式。"
                    }
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.tearDownPlayer()
                self.isLoading = false
                if let requested = self.requestedDecoder {
                    self.playbackNotice = "切换至\(requested.title)失败：\(error.localizedDescription)"
                    self.requestedDecoder = nil
                }
                self.errorMessage = error.localizedDescription
                self.log("加载失败：\(error.localizedDescription)")
            }
        }
    }

    func togglePlayback() {
        guard canControl else { return }
        if core.snapshot.phase == .ended, let currentItem {
            load(currentItem, source: source, engine: currentEngine, decoder: currentDecoder, position: 0)
            return
        }
        if isPlaying { core.pause() } else { core.play() }
        pipController?.invalidatePlaybackState()
    }

    func pause() {
        core.pause()
        pipController?.invalidatePlaybackState()
        recordPlaybackHistory()
    }

    func seek(to time: TimeInterval, resume: Bool? = nil) {
        guard canSeek, time.isFinite else { return }
        let target = min(max(0, time), duration)
        pendingSeek = (target, resume ?? isPlaying)
        seekLanding = (target, Date().addingTimeInterval(3))
        currentTime = target
        isSeeking = true
        performPendingSeek()
    }

    // Coalesce scrub previews: at most one decoder seek is in flight, and the
    // final release target always replaces any older preview waiting behind it.
    private func performPendingSeek() {
        guard !seekInFlight, let next = pendingSeek, core.driver != nil else { return }
        pendingSeek = nil
        seekInFlight = true
        let token = generation
        core.seek(to: next.time, resume: next.resume) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.seekInFlight = false
                if self.pendingSeek != nil { self.performPendingSeek() }
                else {
                    self.currentTime = finished ? next.time : max(0, self.core.snapshot.time)
                    self.seekLanding = finished ? (next.time, Date().addingTimeInterval(2)) : nil
                    self.isSeeking = false
                    self.updateSubtitles()
                    if finished { self.embySession?.didSeek(to: next.time, paused: !self.isPlaying) }
                }
            }
        }
    }

    func toggleMute() {
        isMuted.toggle()
        core.configure(engineConfiguration)
    }

    func unmute() {
        isMuted = false
        core.configure(engineConfiguration)
    }

    func startPictureInPicture() {
        configurePictureInPicture()
        guard core.snapshot.pipPossible || pipController?.isPictureInPicturePossible == true else {
            playbackNotice = String(localized: "当前视频暂不支持画中画。")
            return
        }
        core.startPiP()
    }

    private var automaticallyStartsPictureInPicture: Bool {
        PlaybackPreferences.backgroundEnabled && PlaybackPreferences.backgroundMode == "pip"
    }

    private func configurePictureInPicture() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let candidate = core.nativePiPController else {
            pipController?.delegate = nil
            pipController = nil
            pipObservation = nil
            pipConfigurationObservation = nil
            return
        }
        candidate.canStartPictureInPictureAutomaticallyFromInline = automaticallyStartsPictureInPicture
        guard candidate !== pipController else { return }
        pipController?.delegate = nil
        pipController?.stopPictureInPicture()
        pipObservation = nil
        pipConfigurationObservation = nil
        // The Aether bridge owns its native/sample-buffer content source.
        pipController = candidate
        candidate.delegate = self
        log("PlaybackCore 画中画配置：automatic=\(candidate.canStartPictureInPictureAutomaticallyFromInline) policy=\(backgroundPolicyID)")
        isPictureInPicturePossible = candidate.isPictureInPicturePossible
        pipConfigurationObservation = candidate.observe(\.canStartPictureInPictureAutomaticallyFromInline, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor in
                guard let self, !self.automaticallyStartsPictureInPicture else { return }
                self.pipController?.canStartPictureInPictureAutomaticallyFromInline = false
            }
        }
        let identity = ObjectIdentifier(candidate)
        pipObservation = candidate.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, change in
            let possible = change.newValue ?? false
            Task { @MainActor in
                guard let self, let current = self.pipController, ObjectIdentifier(current) == identity else { return }
                self.isPictureInPicturePossible = possible
            }
        }
    }

    func playerDidAppear() {
        restoringPiP = false
        if isPictureInPictureActive { core.stopPiP() }
        let completion = restorePiPCompletion
        restorePiPCompletion = nil
        completion?(true)
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === pipController else { return }
        log("PlaybackCore 将进入画中画：automatic=\(controller.canStartPictureInPictureAutomaticallyFromInline) policy=\(backgroundPolicyID) inactive=\(appIsInactive) background=\(appIsInBackground)")
    }

    private func restoreVideoContentMode() {
        core.configure(engineConfiguration)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === pipController else { return }
        guard !(appIsInBackground || appIsInactive) || (PlaybackPreferences.backgroundEnabled && PlaybackPreferences.backgroundMode == "pip") else {
            controller.stopPictureInPicture()
            if !PlaybackPreferences.backgroundEnabled { pause() }
            return
        }
        isPictureInPictureActive = true
        core.setPiPActive(true)
        isPresented = false
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === pipController else { return }
        isPictureInPictureActive = false
        core.setPiPActive(false)
        restoreVideoContentMode()
        if !restoringPiP && !isPresented && !(appIsInBackground && PlaybackPreferences.backgroundEnabled && PlaybackPreferences.backgroundMode == "audio") { pause() }
        restoringPiP = false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard controller === pipController else { return }
        playbackNotice = error.localizedDescription
        if appIsInBackground { pause() }
        restoreVideoContentMode()
        log("画中画启动失败：\(error.localizedDescription)")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard controller === pipController else { completionHandler(false); return }
        restoringPiP = true
        if isPresented { completionHandler(true) }
        else { restorePiPCompletion = completionHandler; isPresented = true }
    }

    private var backgroundPolicyID: String {
        "\(PlaybackPreferences.backgroundEnabled):\(PlaybackPreferences.backgroundMode)"
    }

    func setBackgroundPreferences(enabled: Bool, mode: String) {
        // Persist first, including changes made when no player exists yet.
        UserDefaults.standard.set(enabled, forKey: "player.background.enabled")
        UserDefaults.standard.set(mode, forKey: "player.background.mode")
        refreshPlaybackPreferences()
    }

    func refreshPlaybackPreferences() {
        // SwiftVLC 1.0.0 captures auto-PiP in the native drawable attachment.
        // Recreating PiPVideoView for the SAME Player adopts that old attachment.
        // A new Player is required to change policy before vout is opened.
        if appliedBackgroundPolicy != backgroundPolicyID, core.engineID == .vlc,
           core.driver != nil, let item = currentItem {
            appliedBackgroundPolicy = backgroundPolicyID
            log("后台策略变化，重建 VLC 原生附件：policy=\(backgroundPolicyID)")
            let resume = isPlaying && (!appIsInBackground || PlaybackPreferences.backgroundEnabled)
            if isPictureInPictureActive { isPresented = true }
            load(item, source: source, engine: currentEngine, decoder: currentDecoder,
                 position: currentTime, resume: resume, rate: playbackRate)
            return
        }
        core.configure(engineConfiguration)
        configurePictureInPicture()
        if appliedBackgroundPolicy != backgroundPolicyID {
            appliedBackgroundPolicy = backgroundPolicyID
            log("后台配置：enabled=\(PlaybackPreferences.backgroundEnabled) mode=\(PlaybackPreferences.backgroundMode) automaticPiP=\(automaticallyStartsPictureInPicture) player=\(core.driver != nil)")
        }
        if appIsInBackground {
            if !automaticallyStartsPictureInPicture { core.stopPiP() }
            if !PlaybackPreferences.backgroundEnabled { pause() }
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .inactive:
            appIsInactive = true
            refreshPlaybackPreferences()
        case .background:
            appIsInBackground = true
            saveProgress()
            recordPlaybackHistory()
            if !PlaybackPreferences.backgroundEnabled || PlaybackPreferences.backgroundMode != "pip" { core.stopPiP() }
            guard isPlaying else { return }
            guard PlaybackPreferences.backgroundEnabled else {
                core.stopPiP()
                pause()
                return
            }
            // Native PiP policy is configured on the selected bridge before inactivity.
        case .active:
            appIsInBackground = false
            appIsInactive = false
            pruneUnavailableHistory()
            if isPictureInPictureActive { isPresented = false }
            else if core.driver != nil {
                // Reattach the native rendering layer even when playback was
                // paused before backgrounding. Never resume audio implicitly.
                restoreVideoContentMode()
                if !isPlaying && canSeek { seek(to: currentTime, resume: false) }
                log("前台恢复画面：playing=\(isPlaying) position=\(currentTime)")
            }
        @unknown default: break
        }
    }

    private func recordPlaybackHistory() {
        guard let item = currentItem, let source, source.id == item.id.sourceID, externalFile == nil,
              suppressedProgressID != item.id, currentTime > 0.5, duration > 0 else { return }
        let keepHidden = manuallyUnplayedCurrentItem == item.id
        let priorPlayed = effectivePlayed(for: item)
        let played = !keepHidden && (priorPlayed || currentTime / duration >= 0.9)
        let entry = PlaybackHistoryEntry(mediaID: item.id, title: item.title, source: source,
                                         watchedAt: Date(), position: currentTime, duration: duration,
                                         isPlayed: played, hiddenFromHistory: keepHidden)
        history.removeAll { $0.mediaID == item.id }
        history.insert(entry, at: 0)
        if history.count > 1000 { history.removeLast(history.count - 1000) }
        persistHistory()
        lastHistorySave = Date()
        if !priorPlayed, played, source.kind == .emby {
            submitPlayed(played, for: item, source: source)
        }
    }

    private var progressKey: String? {
        guard externalFile == nil, let id = currentItem?.id else { return nil }
        return id.sourceID.uuidString + ":" + id.localID
    }

    private func saveProgress() {
        guard PlaybackPreferences.remembersProgress, progressRestored, suppressedProgressID != currentItem?.id, let key = progressKey,
              duration > 0, currentTime.isFinite else { return }
        var values = UserDefaults.standard.dictionary(forKey: progressStorageKey) as? [String: Double] ?? [:]
        var durations = UserDefaults.standard.dictionary(forKey: durationStorageKey) as? [String: Double] ?? [:]
        if currentTime >= duration - min(2, duration * 0.05) || currentTime <= 0 {
            values.removeValue(forKey: key); durations.removeValue(forKey: key)
        } else { values[key] = max(0, currentTime); durations[key] = duration }
        UserDefaults.standard.set(values, forKey: progressStorageKey)
        UserDefaults.standard.set(durations, forKey: durationStorageKey)
        savedProgressRevision += 1
        lastProgressSave = Date()
    }

    func clearSavedProgress() {
        UserDefaults.standard.removeObject(forKey: progressStorageKey)
        UserDefaults.standard.removeObject(forKey: durationStorageKey)
        if let currentItem { suppressedProgressID = currentItem.id }
        history.removeAll()
        persistHistory()
        savedProgressRevision += 1
    }

    func savedProgress(for item: MediaItem) -> Double {
        guard PlaybackPreferences.remembersProgress else { return 0 }
        let key = item.id.sourceID.uuidString + ":" + item.id.localID
        let value = UserDefaults.standard.dictionary(forKey: progressStorageKey)?[key] as? Double ?? 0
        return value.isFinite ? max(0, value) : 0
    }

    func savedDuration(for item: MediaItem) -> Double {
        let key = item.id.sourceID.uuidString + ":" + item.id.localID
        let value = UserDefaults.standard.dictionary(forKey: durationStorageKey)?[key] as? Double ?? 0
        return value.isFinite ? max(0, value) : 0
    }

    func clearSavedProgress(for item: MediaItem) {
        let key = item.id.sourceID.uuidString + ":" + item.id.localID
        var values = UserDefaults.standard.dictionary(forKey: progressStorageKey) as? [String: Double] ?? [:]
        var durations = UserDefaults.standard.dictionary(forKey: durationStorageKey) as? [String: Double] ?? [:]
        values.removeValue(forKey: key); durations.removeValue(forKey: key)
        UserDefaults.standard.set(values, forKey: progressStorageKey)
        UserDefaults.standard.set(durations, forKey: durationStorageKey)
        if currentItem?.id == item.id { suppressedProgressID = item.id }
        if let index = history.firstIndex(where: { $0.mediaID == item.id }) {
            let existing = history[index]
            history[index] = PlaybackHistoryEntry(mediaID: existing.mediaID, title: existing.title,
                                                   source: existing.source, watchedAt: existing.watchedAt,
                                                   position: 0, duration: existing.duration,
                                                   isPlayed: existing.isFullyWatched,
                                                   hiddenFromHistory: existing.hiddenFromHistory)
        }
        persistHistory()
        savedProgressRevision += 1
    }

    func effectivePlayed(for item: MediaItem) -> Bool {
        let server = item.isPlayed
        if let edit = playedEdits[item.id] {
            if let syncedAt = edit.syncedAt, let fetchedAt = item.embyPlayedFetchedAt,
               fetchedAt > syncedAt, let server {
                return server
            }
            return edit.played
        }
        return PlaybackHistoryEntry.resolvePlayed(
            server: server,
            local: history.first(where: { $0.mediaID == item.id })?.isFullyWatched
        )
    }

    func setPlayed(_ played: Bool, for item: MediaItem, source: MediaSource,
                   onFailure: ((String) -> Void)? = nil) {
        guard source.id == item.id.sourceID else { return }
        let previousEntry = history.first { $0.mediaID == item.id }
        let previousEdit = playedEdits[item.id]
        let previousPlayed = effectivePlayed(for: item)
        recordPlayed(played, for: item, source: source)
        submitPlayed(played, for: item, source: source) { [weak self] message in
            guard let self else { return }
            self.playedEdits[item.id] = previousEdit
            self.history.removeAll { $0.mediaID == item.id }
            if let previousEntry { self.history.insert(previousEntry, at: 0) }
            if self.currentItem?.id == item.id {
                self.currentItem?.isPlayed = previousPlayed
                self.manuallyUnplayedCurrentItem = previousPlayed ? nil : item.id
            }
            self.persistHistory()
            self.savedProgressRevision += 1
            onFailure?(message)
        }
    }

    private func submitPlayed(_ played: Bool, for item: MediaItem, source: MediaSource,
                              onFailure: ((String) -> Void)? = nil) {
        guard source.kind == .emby, source.emby?.userID != nil else { return }
        let editID = UUID()
        playedEdits[item.id] = PlayedEdit(id: editID, played: played)
        let write = enqueueEmbyRecordWrite(.setPlayed(played), for: item, source: source)
        Task {
            do {
                try await write.value
                guard playedEdits[item.id]?.id == editID else { return }
                playedEdits[item.id]?.syncedAt = Date()
            } catch {
                log("Emby 观看标记同步失败：\(error.localizedDescription)")
                if playedEdits[item.id]?.id == editID {
                    onFailure?(error.localizedDescription)
                }
            }
        }
    }

    /// Clear server progress first, then its local resume state. Does not change watched/favorite state.
    func clearProgress(for item: MediaItem, source: MediaSource, syncServer: Bool = true) async throws {
        if syncServer, source.kind == .emby {
            try await enqueueEmbyRecordWrite(.clearProgress, for: item, source: source).value
        }
        clearSavedProgress(for: item)
    }

    /// Favorites use the same per-item queue as watched/progress writes.
    func setFavorite(_ favorite: Bool, for item: MediaItem, source: MediaSource) async throws {
        guard source.id == item.id.sourceID, source.kind == .emby else { throw EmbyError.invalidResponse }
        try await enqueueEmbyRecordWrite(.setFavorite(favorite), for: item, source: source).value
    }

    // Serialize all user actions for one item without blocking its next UI action.
    func enqueueEmbyRecordWrite(_ change: EmbyPlaybackRecordChange, for item: MediaItem,
                                source: MediaSource) -> Task<Void, Error> {
        let previous = recordWrites[item.id]?.task
        let writeID = UUID()
        let task = Task { [weak self] in
            if let previous { _ = await previous.result }
            defer {
                if let self, self.recordWrites[item.id]?.id == writeID {
                    self.recordWrites.removeValue(forKey: item.id)
                }
            }
            do {
                try await EmbyRepository.shared.updatePlaybackRecord(for: item, source: source, change: change)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let operation: String
                switch change {
                case .clearProgress: operation = "清除播放进度"
                case .setPlayed: operation = "更新观看标记"
                case .setFavorite: operation = "更新收藏状态"
                }
                let failure = EmbyOperationFailure(operation: operation, itemID: item.id.localID,
                                                   sourceID: source.id, reason: error.localizedDescription)
                self?.log("Emby action source=\(source.id) item=\(item.id.localID) operation=\(operation): \(error.localizedDescription)")
                throw failure
            }
        }
        recordWrites[item.id] = EmbyRecordWrite(id: writeID, task: task)
        return task
    }

    private func recordPlayed(_ played: Bool, for item: MediaItem, source: MediaSource) {
        guard source.id == item.id.sourceID else { return }
        let existing = history.first(where: { $0.mediaID == item.id })
        let duration = max(existing?.duration ?? item.duration ?? savedDuration(for: item), 0)
        let position = existing?.position ?? savedProgress(for: item)
        let entry = PlaybackHistoryEntry(
            mediaID: item.id,
            title: item.title,
            source: source,
            watchedAt: Date(),
            position: position,
            duration: duration,
            isPlayed: played,
            hiddenFromHistory: !played
        )
        history.removeAll { $0.mediaID == item.id }
        history.insert(entry, at: 0)
        if history.count > 1000 { history.removeLast(history.count - 1000) }
        if currentItem?.id == item.id {
            currentItem?.isPlayed = played
            manuallyUnplayedCurrentItem = played ? nil : item.id
        }
        persistHistory()
        savedProgressRevision += 1
    }

    /// Called after a successful file deletion; directory deletion also removes
    /// descendant entries. Suppress the active item so a later stop cannot save it again.
    func removePlaybackData(sourceID: UUID, path: String, includingDescendants: Bool) {
        removePlaybackData { id in
            id.sourceID == sourceID && (id.localID == path || (includingDescendants && id.localID.hasPrefix(path + "/")))
        }
    }

    private func removePlaybackData(matching matches: (MediaID) -> Bool) {
        if let currentItem, matches(currentItem.id) { suppressedProgressID = currentItem.id }
        history.removeAll { matches($0.mediaID) }
        for storageKey in [progressStorageKey, durationStorageKey] {
            var values = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Double] ?? [:]
            for key in Array(values.keys) {
                guard let separator = key.firstIndex(of: ":"),
                      let sourceID = UUID(uuidString: String(key[..<separator])) else { continue }
                let id = MediaID(sourceID: sourceID, localID: String(key[key.index(after: separator)...]))
                if matches(id) { values.removeValue(forKey: key) }
            }
            UserDefaults.standard.set(values, forKey: storageKey)
        }
        persistHistory()
        savedProgressRevision += 1
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "player.history.v1")
        }
    }

    /// Reconcile files deleted outside Vesper when returning to the app. A loss
    /// of permission alone is not evidence that a video was deleted.
    func pruneUnavailableHistory() {
        var missing = Set<MediaID>()
        let photoAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        for entry in history {
            switch entry.source.kind {
            case .local:
                guard let root = try? entry.source.localFolderURL() else { continue }
                let scoped = root.startAccessingSecurityScopedResource()
                defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                guard FileManager.default.isReadableFile(atPath: root.path) else { continue }
                let path = entry.mediaID.localID
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                    missing.insert(entry.mediaID)
                    continue
                }
                do {
                    let values = try root.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey])
                    if values.isRegularFile != true { missing.insert(entry.mediaID) }
                } catch {
                    let failure = error as NSError
                    if failure.domain == NSCocoaErrorDomain,
                       [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) {
                        missing.insert(entry.mediaID)
                    }
                }
            case .photos:
                if photoAccess == .authorized,
                   PHAsset.fetchAssets(withLocalIdentifiers: [entry.mediaID.localID], options: nil).count == 0 {
                    missing.insert(entry.mediaID)
                }
            case .demo, .emby: break
            }
        }
        if !missing.isEmpty { removePlaybackData { missing.contains($0) } }
    }

    private func restoreProgressIfNeeded() {
        guard !progressRestored, canSeek else { return }
        progressRestored = true
        guard PlaybackPreferences.remembersProgress, let key = progressKey,
              let saved = UserDefaults.standard.dictionary(forKey: progressStorageKey)?[key] as? Double,
              saved > 0, saved < duration - min(2, duration * 0.05) else { return }
        seek(to: saved, resume: isPlaying)
    }

    func mediaDetails() async -> PlaybackVideoDetails? {
        if let source, source.kind == .emby, let item = currentItem {
            return try? await EmbyRepository.shared.details(for: item, source: source).video
        }
        guard let resource else { return nil }
        let token = generation
        let url = resource.url
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        var dimensions: String?
        if let track = tracks.first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let transformed = size.applying(transform)
            dimensions = "\(Int(abs(transformed.width).rounded())) × \(Int(abs(transformed.height).rounded()))"
        }
        var technical: [PlaybackDetailField] = []
        technical.append(.init(label: "视频轨道数量", value: String(tracks.count)))
        if let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
            if let date = values.creationDate { technical.append(.init(label: "创建时间", value: date.formatted())) }
            if let date = values.contentModificationDate { technical.append(.init(label: "修改时间", value: date.formatted())) }
        }
        for (index, track) in tracks.enumerated() {
            let prefix = "Video \(index + 1)"
            if let size = try? await track.load(.naturalSize), size.height != 0 {
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let display = size.applying(transform)
                let w = Int(abs(display.width).rounded()), h = Int(abs(display.height).rounded())
                func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
                let divisor = max(1, gcd(w, h))
                technical.append(.init(label: "画面比例", value: "\(w / divisor):\(h / divisor)"))
            }
            if let rate = try? await track.load(.nominalFrameRate), rate > 0 { technical.append(.init(label: "帧率", value: String(format: "%.3f fps", rate))) }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 { technical.append(.init(label: "视频码率", value: Self.bitRateLabel(Double(rate)))) }
            if let descriptions = try? await track.load(.formatDescriptions) {
                for format in descriptions {
                    technical.append(.init(label: "视频编码", value: "\(prefix) · \(Self.codecName(format))"))
                    technical += Self.videoColorDetails(format)
                    let size = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true)
                    if size.width > 0 && size.height > 0 { technical.append(.init(label: "显示尺寸", value: "\(Int(size.width)) × \(Int(size.height))")) }
                }
            }
        }
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        technical.append(.init(label: "音轨数量", value: String(audioTracks.isEmpty ? core.snapshot.audio.count : audioTracks.count)))
        for (index, track) in audioTracks.enumerated() {
            let prefix = "Audio \(index + 1)"
            if let language = try? await track.load(.languageCode) { technical.append(.init(label: "音频语言", value: "\(prefix) · \(language)")) }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 { technical.append(.init(label: "音频码率", value: Self.bitRateLabel(Double(rate)))) }
            if let descriptions = try? await track.load(.formatDescriptions) {
                for format in descriptions {
                    technical.append(.init(label: "音频编码", value: "\(prefix) · \(Self.codecName(format))"))
                    technical += Self.audioLayoutDetails(format)
                    if let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                        technical.append(.init(label: "采样率", value: String(format: "%.0f Hz", stream.mSampleRate)))
                        technical.append(.init(label: "声道数", value: String(stream.mChannelsPerFrame)))
                        if stream.mBitsPerChannel > 0 { technical.append(.init(label: "音频位深", value: "\(stream.mBitsPerChannel) bit")) }
                    }
                }
            }
        }
        if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, duration > 0 {
            technical.append(.init(label: "总码率", value: Self.bitRateLabel(Double(bytes) * 8 / duration)))
        }
        technical.append(.init(label: "容器格式", value: Self.containerName(url)))
        // Probe the source through the isolated Aether bridge; AVAsset alone
        // omits tracks for TS/MKV and must not report those as zero streams.
        if let probe = try? await Task.detached(priority: .utility, operation: { try AetherMediaProbe.inspect(url) }).value {
            let labels = Set(probe.fields.keys)
            technical.removeAll { labels.contains($0.label) }
            technical += probe.fields.sorted { $0.key < $1.key }.map { .init(label: $0.key, value: $0.value) }
            if let container = probe.container {
                technical.removeAll { $0.label == "容器格式" }
                technical.append(.init(label: "容器格式", value: container))
            }
            if probe.width > 0 && probe.height > 0 { dimensions = "\(probe.width) × \(probe.height)" }
        }
        var synopsis: String?
        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata where item.commonKey == .commonKeyDescription {
                if let text = try? await item.load(.stringValue), !text.isEmpty {
                    synopsis = text
                    break
                }
            }
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileName = externalFile?.name ?? (source?.kind == .local ? URL(fileURLWithPath: currentItem?.id.localID ?? "").lastPathComponent : currentItem?.title)
        guard generation == token else { return nil }
        return PlaybackVideoDetails(fileName: fileName ?? "", dimensions: dimensions,
                                    byteCount: values?.fileSize, synopsis: synopsis,
                                    sourceName: source?.name ?? VesperLocalization.string("外部视频"), technical: technical)
    }

    private static func bitRateLabel(_ bitsPerSecond: Double) -> String {
        guard bitsPerSecond.isFinite, bitsPerSecond > 0 else { return "—" }
        if bitsPerSecond >= 1_000_000 { return String(format: "%.2f Mbit/s", bitsPerSecond / 1_000_000) }
        if bitsPerSecond >= 1_000 { return String(format: "%.1f kbit/s", bitsPerSecond / 1_000) }
        return String(format: "%.0f bit/s", bitsPerSecond)
    }

    private static func containerName(_ url: URL) -> String {
        if url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 64) {
                let bytes = Array(data)
                if bytes.count >= 12, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" {
                    return String(bytes: bytes[8..<12], encoding: .ascii) == "qt  " ? "QuickTime / MOV" : "ISO BMFF / MP4"
                }
                if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "Matroska / WebM" }
                if bytes.starts(with: Array("FLV".utf8)) { return "FLV" }
                if bytes.starts(with: Array("OggS".utf8)) { return "Ogg" }
                if bytes.first == 0x47 { return "MPEG-TS" }
                if bytes.count >= 12, String(bytes: bytes[8..<12], encoding: .ascii) == "AVI " { return "AVI" }
            }
        }
        return url.pathExtension.isEmpty ? "—" : url.pathExtension.uppercased()
    }

    private static func videoColorDetails(_ format: CMFormatDescription) -> [PlaybackDetailField] {
        let extensions = (CMFormatDescriptionGetExtensions(format) as? [String: Any]) ?? [:]
        var fields: [PlaybackDetailField] = []
        let transfer = String(describing: extensions["TransferFunction"] ?? "")
        let codec = codecName(format)
        let range: String
        if ["dvhe", "dvh1", "dva1", "dvav"].contains(codec) { range = "Dolby Vision" }
        else if transfer.contains("2084") { range = "HDR (PQ / HDR10)" }
        else if transfer.contains("HLG") { range = "HDR (HLG)" }
        else { range = "SDR" }
        fields.append(.init(label: "动态范围", value: range))
        for (key, label) in [("ColorPrimaries", "色彩原色"), ("TransferFunction", "传递函数"), ("YCbCrMatrix", "色彩矩阵"), ("BitsPerComponent", "视频位深"), ("FullRangeVideo", "全范围色彩")] {
            if let value = extensions[key] { fields.append(.init(label: label, value: String(describing: value))) }
        }
        return fields
    }

    private static func audioLayoutDetails(_ format: CMFormatDescription) -> [PlaybackDetailField] {
        var layoutSize = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(format, sizeOut: &layoutSize) else { return [] }
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutName, UInt32(layoutSize), layout, &size, &name)
        let value = status == noErr ? name.map { $0 as String } : nil
        return [.init(label: "声道布局", value: value ?? String(format: "0x%08X", layout.pointee.mChannelLayoutTag))]
    }

    private static func codecName(_ description: CMFormatDescription) -> String {
        let code = CMFormatDescriptionGetMediaSubType(description)
        let bytes: [UInt8] = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? String(code)
    }

    func progress(for item: MediaItem) -> Double {
        if item.id == currentItem?.id { return currentTime }
        let key = item.id.sourceID.uuidString + ":" + item.id.localID
        return UserDefaults.standard.dictionary(forKey: progressStorageKey)?[key] as? Double ?? 0
    }

    func queueInfo(for item: MediaItem) async -> PlaybackQueueInfo {
        guard let source, source.id == item.id.sourceID else { return .init() }
        if source.kind == .emby { return .init(duration: item.duration ?? 0) }
        if source.kind == .photos {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id.localID], options: nil).firstObject else { return .init() }
            PlayerQueueDiagnostic.write("photos.metadata.begin id=\(item.id.localID) authorization=\(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)")
            let bytes = await QueuePhotoMetadataRequest().load(asset)
            PlayerQueueDiagnostic.write("photos.metadata.end id=\(item.id.localID) duration=\(asset.duration) bytes=\(bytes ?? -1)")
            return .init(duration: asset.duration.isFinite ? asset.duration : 0, dimensions: "\(asset.pixelWidth) × \(asset.pixelHeight)", byteCount: bytes)
        }
        guard source.kind == .local, let resource = try? await PlaybackResourceResolver().resolve(item, source: source) else { return .init() }
        defer { resource.release() }
        let asset = AVURLAsset(url: resource.url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        var dimensions: String?
        if let track = tracks.first, let size = try? await track.load(.naturalSize) {
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let size = size.applying(transform)
            dimensions = "\(Int(abs(size.width))) × \(Int(abs(size.height)))"
        }
        let bytes = try? resource.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return .init(duration: duration.isFinite ? duration : 0, dimensions: dimensions, byteCount: bytes)
    }

    func setPlaybackRate(_ rate: Float) {
        guard [Float(0.5), 0.75, 1, 1.25, 1.5, 2].contains(rate) else { return }
        playbackRate = rate
        core.configure(engineConfiguration)
    }

    func toggleFill() {
        fillsScreen.toggle()
        if !isPictureInPictureActive { restoreVideoContentMode() }
    }

    func playQueued(_ item: MediaItem) {
        guard let source, queue.contains(where: { $0.id == item.id }) else { return }
        load(item, source: source, engine: currentEngine, decoder: currentDecoder)
    }

    func selectAudio(_ id: Int32) {
        guard let key = trackIDs.first(where: { $0.value == id })?.key else { return }
        core.selectAudio(key)
        refreshTracks()
    }
    func selectSubtitle(_ id: Int32?) {
        let key = id.flatMap { value in trackIDs.first { $0.value == value }?.key }
        core.selectSubtitle(key)
        selectedSubtitleID = id
        refreshTracks()
    }
    private func uiTrackID(_ id: String) -> Int32 {
        if let value = trackIDs[id] { return value }
        let value = nextTrackID; nextTrackID += 1; trackIDs[id] = value; return value
    }
    private func refreshTracks() {
        let state = core.driver?.snapshot ?? core.snapshot
        let audio = state.audio.map { PlaybackTrack(id: uiTrackID($0.id), name: $0.name, isSelected: $0.selected) }
        let subtitles = state.subtitles.map { PlaybackTrack(id: uiTrackID($0.id), name: $0.name, isSelected: $0.selected) }
        if audioTracks != audio { audioTracks = audio }
        if subtitleTracks != subtitles { subtitleTracks = subtitles }
        selectedSubtitleID = state.subtitles.first(where: { $0.selected }).map { uiTrackID($0.id) }
    }
    private func updateSubtitles() {
        let state = core.snapshot
        if subtitleText != state.subtitleText { subtitleText = state.subtitleText }
        if subtitleImage !== state.subtitleImage { subtitleImage = state.subtitleImage }
    }

    func next() {
        guard hasNext, let source, let currentItem,
              let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return }
        // Both bridges currently retire their PiP source during load. Present
        // the new video instead of silently leaving audio with no PiP window.
        if isPictureInPictureActive { isPresented = true }
        load(queue[index + 1], source: source, engine: currentEngine, decoder: currentDecoder)
    }

    func retry() {
        guard let currentItem else { return }
        load(currentItem, source: source, engine: currentEngine, decoder: currentDecoder)
    }

    func stop() {
        saveProgress()
        recordPlaybackHistory()
        request?.cancel()
        request = nil
        generation = UUID()
        tearDownPlayer()
        currentItem = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        source = nil
        externalFile = nil
        queue = []
        currentTime = 0
        duration = 0
        isLoading = false
        errorMessage = nil
        isPresented = false
        let stoppedGeneration = generation
        Task { [weak self] in
            await self?.core.waitUntilRetired()
            guard let self, self.generation == stoppedGeneration, self.currentItem == nil else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func tearDownPlayer() {
        pipController?.delegate = nil
        core.stopPiP()
        pipObservation = nil
        pipConfigurationObservation = nil
        pipController = nil
        isPictureInPicturePossible = false
        isPictureInPictureActive = false
        previouslyActivePiP = false
        restorePiPCompletion?(false)
        restorePiPCompletion = nil
        restoringPiP = false
        pendingSeek = nil
        seekInFlight = false
        seekLanding = nil
        let retirement = core.shutdown()
        let retiringEmbySession = embySession
        embySession = nil
        let retiringResource = resource
        Task {
            await retirement.value
            if let ending = retiringEmbySession?.finish() { await ending.value }
            retiringResource?.release()
        }
        videoView?.removeFromSuperview()
        videoView = nil
        trackIDs = [:]; nextTrackID = 1
        resource = nil
        subtitleText = ""
        subtitleImage = nil
        selectedSubtitleID = nil
        audioTracks = []
        subtitleTracks = []
        bufferedTime = 0
        isSeeking = false
        isPlaying = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private var engineConfiguration: EngineConfiguration {
        var value = EngineConfiguration()
        value.decoder = currentDecoder == .software ? .software : .hardware
        value.position = currentTime; value.autoplay = isPlaying
        value.rate = playbackRate; value.muted = isMuted; value.fillsScreen = fillsScreen
        value.backgroundEnabled = PlaybackPreferences.backgroundEnabled
        value.automaticPiP = automaticallyStartsPictureInPicture
        value.subtitleFontSize = UserDefaults.standard.object(forKey: "player.subtitle.fontSize") as? Double ?? 22
        value.subtitleBackground = UserDefaults.standard.object(forKey: "player.subtitle.background") as? Bool ?? true
        value.requestHeaders = resource?.headers ?? [:]
        value.externalSubtitles = resource?.externalSubtitles ?? []
        return value
    }
    private func syncCoreState() {
        let state = core.snapshot
        videoView = core.view
        currentEngine = core.engineID == .aether ? .aether : .vlc
        if let actual = state.actualDecoder { currentDecoder = actual == .software ? .software : .hardware }
        isLoading = core.isTransitioning || state.phase == .loading
        isPlaying = state.phase == .playing
        if appIsInBackground && !PlaybackPreferences.backgroundEnabled && isPlaying { core.pause() }
        if !isSeeking && !core.isTransitioning {
            if let landing = seekLanding {
                if abs(state.time - landing.time) < 1.5 || Date() >= landing.deadline { seekLanding = nil; currentTime = max(0, state.time) }
            } else { currentTime = state.time.isFinite ? max(0, state.time) : 0 }
        }
        if !isLoading || state.duration > 0 {
            let engineDuration = state.duration.isFinite ? max(0, state.duration) : 0
            duration = engineDuration > 0 ? engineDuration : (resource?.duration ?? 0)
        }
        bufferedTime = state.buffered.isFinite ? max(currentTime, state.buffered) : currentTime
        if case .failed(let message) = state.phase { errorMessage = message; isLoading = false }
        if state.phase == .ended {
            currentTime = duration; saveProgress(); recordPlaybackHistory()
            embySession?.finish()
        }
        embySession?.update(position: currentTime, paused: !isPlaying, rate: playbackRate,
                            remembersProgress: PlaybackPreferences.remembersProgress,
                            ready: !isLoading && (state.phase == .playing || state.phase == .paused || state.phase == .ended))
        refreshTracks(); updateSubtitles(); configurePictureInPicture()
        // SwiftVLC retains its native AVKit delegate; consume its observable PiP state.
        isPictureInPicturePossible = state.pipPossible
        if state.pipActive != previouslyActivePiP {
            previouslyActivePiP = state.pipActive
            isPictureInPictureActive = state.pipActive
            if state.pipActive { isPresented = false }
            else if !restoringPiP && !isPresented && !(appIsInBackground && PlaybackPreferences.backgroundEnabled && PlaybackPreferences.backgroundMode == "audio") { pause() }
        }
        restoreProgressIfNeeded()
        if Date().timeIntervalSince(lastProgressSave) >= 5 && !isSeeking { saveProgress() }
        if isPlaying && !isSeeking && Date().timeIntervalSince(lastHistorySave) >= 5 { recordPlaybackHistory() }
        UIApplication.shared.isIdleTimerDisabled = isPlaying
        if !core.isTransitioning {
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyTitle] = currentItem?.title
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }

    private func log(_ message: String) {
        AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [Playback] \(EmbyAPIClient.redacted(message))")
    }
}

struct PlaybackTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
    let isSelected: Bool
}

struct PlaybackVideoDetails: Sendable {
    let fileName: String
    let dimensions: String?
    let byteCount: Int?
    let synopsis: String?
    let sourceName: String
    let technical: [PlaybackDetailField]
}

struct PlaybackDetailField: Sendable {
    let label: String
    let value: String
}

struct PlaybackQueueInfo: Sendable {
    var duration: Double = 0
    var dimensions: String?
    var byteCount: Int?
}

struct PlaybackHistoryEntry: Identifiable, Codable {
    let mediaID: MediaID
    let title: String
    let source: MediaSource
    let watchedAt: Date
    let position: Double
    let duration: Double
    var isPlayed: Bool? = nil
    var isCompleted: Bool? = nil
    var hiddenFromHistory: Bool? = nil
    var id: MediaID { mediaID }
    var isFullyWatched: Bool { isPlayed ?? isCompleted ?? false }
    static func resolvePlayed(trakt: Bool? = nil, server: Bool?, local: Bool?) -> Bool {
        trakt ?? server ?? local ?? false
    }
    var item: MediaItem {
        MediaItem(id: mediaID, title: title, resource: nil,
                  embyItemID: source.kind == .emby ? mediaID.localID : nil, duration: duration,
                  isPlayed: isFullyWatched)
    }
}

/// Photos invokes callbacks off the main actor. Resume a request exactly once,
/// including cancellation, without inheriting the session's actor isolation.
@MainActor
private final class QueuePhotoMetadataRequest {
    private var continuation: CheckedContinuation<Int?, Never>?
    private var requestID: PHImageRequestID?

    func load(_ asset: PHAsset) async -> Int? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                self.continuation = continuation
                let options = PHVideoRequestOptions()
                options.isNetworkAccessAllowed = false
                options.deliveryMode = .fastFormat
                requestID = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { @Sendable [weak self] avAsset, _, info in
                    let bytes = (avAsset as? AVURLAsset).flatMap { try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize }
                    let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                    let error = (info?[PHImageErrorKey] as? NSError)?.code
                    let hasAsset = avAsset != nil
                    Task { @MainActor [weak self] in
                        PlayerQueueDiagnostic.write("photos.metadata.callback asset=\(hasAsset) cancelled=\(cancelled) error=\(error.map(String.init) ?? "none")")
                        self?.finish(bytes)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let requestID = self.requestID { PHImageManager.default().cancelImageRequest(requestID) }
                self.finish(nil)
            }
        }
    }

    private func finish(_ bytes: Int?) {
        let pending = continuation
        continuation = nil
        requestID = nil
        pending?.resume(returning: bytes)
    }
}
