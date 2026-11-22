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
import Observation

/// High-frequency values are observed only by the timeline, speed label and danmaku.
/// They must not broadcast through the app-wide PlaybackSession publisher.
@MainActor @Observable
final class PlaybackTimelineState {
    var currentTime: TimeInterval = 0
    var bufferedTime: TimeInterval = 0
    var bufferedRanges: [ClosedRange<Double>] = []
    var downloadBytesPerSecond: Double?
}

/// A single app-owned session. Tabs and player presentation never own or reset
/// the decoder. PlaybackCore owns engine scheduling behind the existing UI API.
@MainActor
final class PlaybackSession: NSObject, ObservableObject, @preconcurrency AVPictureInPictureControllerDelegate {
    let timeline = PlaybackTimelineState()
    @Published private(set) var currentEngine = PlaybackPreferences.preferredEngine
    var diagnosticEngineTitle: String { currentEngine.title }
    var diagnosticMetrics: [EngineDiagnosticMetric] {
        [.init("下载速度", downloadSpeedText)] + (core.driver?.diagnosticMetrics ?? [])
    }
    private(set) var downloadBytesPerSecond: Double? {
        get { timeline.downloadBytesPerSecond }
        set { if timeline.downloadBytesPerSecond != newValue { timeline.downloadBytesPerSecond = newValue } }
    }
    private var downloadSpeedSampler = DownloadSpeedSampler()
    var downloadSpeedText: String {
        if downloadBytesPerSecond == nil || downloadBytesPerSecond == 0 { return "0B/s" }
        return DownloadSpeedSampler.megabytesPerSecond(downloadBytesPerSecond)
    }

    // Runs while PlayerScreen is mounted, including the initial async engine load.
    // SwiftUI cancels it on dismissal; no independent timer keeps the player alive.
    func monitorDownloadSpeed() async {
        defer {
            downloadSpeedSampler = DownloadSpeedSampler()
            downloadBytesPerSecond = nil
        }
        while !Task.isCancelled {
            downloadBytesPerSecond = downloadSpeedSampler.update(
                core.driver?.downloadSample, at: ProcessInfo.processInfo.systemUptime)
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }
    @Published private(set) var currentDecoder = PlaybackPreferences.preferredDecoder
    @Published private(set) var playbackSubtitle: String?
    private var playbackSubtitleTask: Task<Void, Never>?
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
    // Preserve write order, including deletes, without encoding the full history
    // on the main actor while video and controls are rendering.
    private let historyPersistenceQueue = DispatchQueue(label: "app.vesper.playback.history", qos: .utility)
    @Published private(set) var currentItem: MediaItem? {
        didSet {
            if oldValue?.id != currentItem?.id { danmaku = PlayerDanmaku() }
        }
    }
    @Published private(set) var danmaku = PlayerDanmaku()
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedMedia = false
    var canShowMediaDetails: Bool {
        guard currentItem != nil, core.driver != nil, errorMessage == nil else { return false }
        return core.playbackURL?.isFileURL == true || hasLoadedMedia
    }
    private(set) var currentTime: TimeInterval {
        get { timeline.currentTime }
        set { if timeline.currentTime != newValue { timeline.currentTime = newValue } }
    }
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var videoView: UIView?
    @Published var isPresented = false {
        didSet { core.isPlayerPresented = isPresented }
    }
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var fillsScreen = false
    private(set) var bufferedTime: TimeInterval {
        get { timeline.bufferedTime }
        set { if timeline.bufferedTime != newValue { timeline.bufferedTime = newValue } }
    }
    private(set) var bufferedRanges: [ClosedRange<Double>] {
        get { timeline.bufferedRanges }
        set { if timeline.bufferedRanges != newValue { timeline.bufferedRanges = newValue } }
    }
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
    @Published private var subtitleSizes: [PlaybackEngine: Double] = [:]
    var subtitleSize: Double { subtitleSizes[currentEngine] ?? 22 }
    @Published private(set) var subtitleDelay: Double = 0

    func setSubtitleSize(_ value: Double) {
        guard value.isFinite else { return }
        subtitleSizes[currentEngine] = min(40, max(14, value))
        core.configure(engineConfiguration)
    }

    func setSubtitleDelay(_ value: Double) {
        guard currentEngine == .vlc, value.isFinite else { return }
        subtitleDelay = min(30, max(-30, value))
        core.configure(engineConfiguration)
    }
    struct PlaybackTransitionNotice: Equatable {
        let id = UUID()
        let message: String
    }
    @Published private(set) var playbackTransitionNotice: PlaybackTransitionNotice?
    struct AutomaticSkipNotice: Equatable {
        enum Kind: Equatable { case intro, outro }
        let id = UUID()
        let kind: Kind
    }
    @Published private(set) var automaticSkipNotice: AutomaticSkipNotice?
    private var pipStartTask: Task<Void, Never>?
    private var pipController: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private var pipConfigurationObservation: NSKeyValueObservation?
    private var preferencesObservation: AnyCancellable?
    private var appliedBackgroundPolicy = ""
    private var restorePiPCompletion: ((Bool) -> Void)?
    private var restoringPiP = false
    private var pendingSeek: (time: TimeInterval, resume: Bool, preview: Bool)?
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
        wireCore()
        refreshPlaybackPreferences()
        preferencesObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshSkipMarkers()
                    if self.appliedBackgroundPolicy != self.backgroundPolicyID { self.refreshPlaybackPreferences() }
                }
            }
        let savedRate = UserDefaults.standard.float(forKey: "player.playbackRate")
        if [Float(0.5), 0.75, 1, 1.25, 1.5, 2].contains(savedRate) { playbackRate = savedRate }
    }

    private func wireCore() {
        core.onChange = { [weak self] in self?.syncCoreState() }
        core.log = { [weak self] in self?.log($0) }
        core.onEngineFallback = { [weak self] from, to in
            let previous: PlaybackEngine = from == .aether ? .aether : .vlc
            let next: PlaybackEngine = to == .aether ? .aether : .vlc
            self?.playbackTransitionNotice = .init(message: "\(previous.title) 无法播放，正在切换至 \(next.title)")
        }
        core.restoreUI = { [weak self] completion in
            guard let self else { completion(false); return }
            self.restoringPiP = true
            if self.isPresented { completion(true) }
            else { self.restorePiPCompletion = completion; self.isPresented = true }
        }
    }

    private let core = PlaybackCore()
    private let traktReporter = TraktPlaybackReporter()
    private var nextPreparation: Task<Void, Never>?
    private var nextPreparationID: MediaID?
    private var attemptedNextForGeneration: UUID?
    private var lastNextPolicyAttempt = Date.distantPast
    private var preparedNext: (item: MediaItem, sourceID: UUID, resource: ResolvedPlaybackResource)?

    private var trackIDs: [String: Int32] = [:]
    private var nextTrackID: Int32 = 1
    private var previouslyActivePiP = false
    private var requestedDecoder: PlaybackDecoder?
    private var decoderChange: Task<Void, Never>?
    private var resource: ResolvedPlaybackResource?
    private var embySession: EmbyPlaybackSession?
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private var skipMarkers = EmbySkipMarkers.empty
    private var skipLookupTask: Task<Void, Never>?
    private var skipLookupIdentity: String?
    private var skippedIntroEnds = Set<Double>()
    private var skippedCredits = false
    @Published private(set) var queue: [MediaItem] = []
    private var source: MediaSource?
    private var externalFile: IncomingVideo?

    var queueSource: MediaSource? { source }

    var hasNext: Bool {
        guard let currentItem, let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return false }
        return index + 1 < queue.count
    }
    var canControl: Bool {
        core.driver != nil && !core.isTransitioning && !core.snapshot.requiresForegroundReload && errorMessage == nil
    }
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
        guard decoder != currentDecoder, currentItem != nil, decoderChange == nil, canControl else { return }
        // SwiftVLC 1.0.0 has no presented-frame readiness acknowledgement.
        // A detached paused candidate can open audio without a usable drawable,
        // so do not use the speculative dual-player path for this bridge.
        if currentEngine == .vlc, let item = currentItem {
            load(item, source: source, engine: .vlc, decoder: decoder,
                 position: currentTime, resume: isPlaying, rate: playbackRate,
                 reportsDecoderChange: true)
            return
        }
        let token = generation
        requestedDecoder = decoder
        decoderChange = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token { self.decoderChange = nil; self.requestedDecoder = nil }
            }
            do {
                let actual = try await self.core.switchDecoder(to: decoder == .software ? .software : .hardware)
                guard !Task.isCancelled, self.generation == token else { return }
                self.currentDecoder = actual.map { $0 == .software ? .software : .hardware } ?? decoder
                self.playbackTransitionNotice = .init(message: actual == nil
                    ? "已应用\(decoder.title)设置" : "已切换至\(decoder.title)")
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.playbackTransitionNotice = .init(message: "切换至\(decoder.title)失败，继续使用原解码")
                self.log("后台切换解码失败：\(error.localizedDescription)")
            }
        }
    }

    func setCurrentEngine(_ engine: PlaybackEngine) {
        guard engine != currentEngine, let item = currentItem else { return }
        load(item, source: source, engine: engine, decoder: currentDecoder,
             position: currentTime, resume: isPlaying, rate: playbackRate)
    }

    private func load(_ item: MediaItem, source: MediaSource?, engine: PlaybackEngine? = nil, decoder: PlaybackDecoder? = nil,
                      position: Double? = nil, resume: Bool = true, rate: Float? = nil,
                      initialAudio: EngineTrack? = nil, initialSubtitle: EngineTrack? = nil,
                      reportsDecoderChange: Bool = false) {
        let warmed = preparedNext.flatMap { prepared in
            prepared.item.id == item.id && (item.embyMediaSourceID == nil || prepared.item.embyMediaSourceID == item.embyMediaSourceID)
                && prepared.sourceID == source?.id && position == nil
                && (engine ?? PlaybackPreferences.preferredEngine) == .aether ? prepared : nil
        }
        if warmed != nil { preparedNext = nil }
        cancelNextPreparation(discardBytes: warmed == nil)
        let item = warmed?.item ?? item
        request?.cancel()
        generation = UUID()
        skipLookupTask?.cancel()
        skipMarkers = .empty
        skipLookupIdentity = nil
        skippedIntroEnds = []
        skippedCredits = false
        let token = generation
        let previousState = core.snapshot
        let carriesSelection = currentItem?.id == item.id && position != nil
        if !carriesSelection || previousState.phase == .ended { traktReporter.finish() }
        let previousAudio = carriesSelection ? previousState.audio.first(where: { $0.selected }) : initialAudio
        let previousSubtitle = carriesSelection ? previousState.subtitles.first(where: { $0.selected }) : initialSubtitle
        saveProgress()
        recordPlaybackHistory()
        tearDownPlayer()
        requestedDecoder = reportsDecoderChange ? decoder : nil
        lastHistorySave = .distantPast
        if !carriesSelection { manuallyUnplayedCurrentItem = nil }
        progressRestored = position != nil
        currentEngine = engine ?? PlaybackPreferences.preferredEngine
        currentDecoder = decoder ?? PlaybackPreferences.preferredDecoder
        suppressedProgressID = nil
        currentItem = item
        hasLoadedMedia = false
        refreshPlaybackSubtitle(for: item, source: source, token: token)
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
                if let warmed {
                    resolved = warmed.resource
                } else if let external {
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
                let startPosition: Double
                if let position { startPosition = position }
                else if PlaybackPreferences.remembersProgress, let source, source.kind == .emby {
                    startPosition = await self.embyResumePosition(for: item, source: source,
                                                                 serverPosition: resolved.resumePosition,
                                                                 duration: resolved.duration ?? item.duration)
                } else {
                    startPosition = PlaybackPreferences.remembersProgress ? self.savedProgress(for: item) : 0
                }
                guard !Task.isCancelled, self.generation == token else { resolved.release(); return }
                self.resource = resolved
                self.downloadSpeedSampler = DownloadSpeedSampler()
                self.downloadBytesPerSecond = nil
                self.refreshSkipMarkers()
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
                configuration.position = startPosition
                configuration.autoplay = resume
                configuration.requestHeaders = resolved.headers
                configuration.externalSubtitles = resolved.externalSubtitles
                configuration.mediaBitRate = resolved.bitRate
                try await self.core.load(resolved.url, preferred: selectedEngine == .aether ? .aether : .vlc,
                                         configuration: configuration, audio: previousAudio, subtitle: previousSubtitle,
                                         server: self.embySession)
                guard !Task.isCancelled, self.generation == token else { return }
                self.syncCoreState()
                if let requested = self.requestedDecoder {
                    self.requestedDecoder = nil
                    if let actual = self.core.snapshot.actualDecoder,
                       (actual == .software) != (requested == .software) {
                        let actualTitle = actual == .software ? PlaybackDecoder.software.title : PlaybackDecoder.hardware.title
                        self.playbackTransitionNotice = .init(message: "不支持\(requested.title)，已切换至\(actualTitle)")
                    } else {
                        let message = self.core.snapshot.actualDecoder == nil
                            ? "已应用\(requested.title)设置" : "已切换至\(requested.title)"
                        self.playbackTransitionNotice = .init(message: message)
                    }
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.tearDownPlayer()
                self.isLoading = false
                if let requested = self.requestedDecoder {
                    self.playbackTransitionNotice = .init(message: "切换至\(requested.title)失败")
                    self.requestedDecoder = nil
                }
                self.errorMessage = error.localizedDescription
                self.log("加载失败：\(error.localizedDescription)")
            }
        }
    }

    func togglePlayback() {
        if restoreReleasedAetherSession(resume: true) { return }
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

    func seek(to time: TimeInterval, resume: Bool? = nil, preview: Bool = false) {
        guard canSeek, time.isFinite else { return }
        let target = min(max(0, time), duration)
        pendingSeek = (target, resume ?? isPlaying, preview)
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
        core.seek(to: next.time, resume: next.resume, fast: next.preview) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.seekInFlight = false
                if self.pendingSeek != nil { self.performPendingSeek() }
                else {
                    self.currentTime = finished ? next.time : max(0, self.core.snapshot.time)
                    self.seekLanding = finished ? (next.time, Date().addingTimeInterval(2)) : nil
                    self.isSeeking = false
                    self.updateSubtitles()
                    if finished && !next.preview { self.embySession?.didSeek(to: next.time, paused: !self.isPlaying) }
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
        guard pipStartTask == nil else { return }
        // Audio mode has no pre-mounted Aether PiP source. Manual opening
        // creates one now; AVKit may need a moment to publish its readiness.
        core.preparePiP()
        configurePictureInPicture()
        if core.engineID != .aether {
            guard core.snapshot.pipPossible else {
                playbackNotice = VesperLocalization.string("当前视频暂不支持画中画。")
                return
            }
            core.startPiP()
            return
        }
        let token = generation
        pipStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.pipStartTask = nil } }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !Task.isCancelled, self.generation == token {
                guard !(self.appIsInBackground || self.appIsInactive) || self.automaticallyStartsPictureInPicture else {
                    self.core.setPiPActive(false)
                    self.configurePictureInPicture()
                    return
                }
                if self.pipController?.isPictureInPicturePossible == true {
                    self.core.startPiP()
                    return
                }
                if ContinuousClock.now >= deadline { break }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard !Task.isCancelled, self.generation == token else { return }
            self.core.setPiPActive(false)
            self.configurePictureInPicture()
            self.playbackNotice = VesperLocalization.string("当前视频暂不支持画中画。")
        }
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
        if candidate.canStartPictureInPictureAutomaticallyFromInline != automaticallyStartsPictureInPicture {
            candidate.canStartPictureInPictureAutomaticallyFromInline = automaticallyStartsPictureInPicture
        }
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
        core.setPiPActive(false)
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
        core.setAppBackgrounded(phase == .background)
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
            if restoreReleasedAetherSession(resume: false) { return }
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

    /// Aether marks a background-released or invalidated pipeline. Re-resolve
    /// the current resource at its last position, keeping Aether as the preferred engine.
    @discardableResult
    private func restoreReleasedAetherSession(resume: Bool) -> Bool {
        guard !appIsInBackground, !appIsInactive, !core.isTransitioning, !isLoading,
              core.engineID == .aether, let item = currentItem,
              core.snapshot.requiresForegroundReload else { return false }
        let position = currentTime.isFinite ? max(0, currentTime) : 0
        log("后台 Aether 视频管线已失效，使用原引擎恢复：position=\(position) resume=\(resume)")
        load(item, source: source, engine: .aether, decoder: currentDecoder,
             position: position, resume: resume, rate: playbackRate)
        return true
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
        var updatedHistory = history.filter { $0.mediaID != item.id }
        updatedHistory.insert(entry, at: 0)
        if updatedHistory.count > 1000 { updatedHistory.removeLast(updatedHistory.count - 1000) }
        history = updatedHistory
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

    /// History removal hides the row while retaining watched-state metadata used by other pages.
    func clearSavedProgress(for item: MediaItem, removeFromHistory: Bool = false) {
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
                                                   hiddenFromHistory: removeFromHistory ? true : existing.hiddenFromHistory)
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
        let shouldClearProgress = !played && !item.isContainer && !item.isEmbySeries
        recordPlayed(played, for: item, source: source)
        submitPlayed(played, for: item, source: source, onSuccess: { [weak self] in
            if shouldClearProgress { self?.clearSavedProgress(for: item) }
        }) { [weak self] message in
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
                              onSuccess: (() -> Void)? = nil,
                              onFailure: ((String) -> Void)? = nil) {
        guard source.kind == .emby, source.emby?.userID != nil else {
            onSuccess?()
            return
        }
        let editID = UUID()
        playedEdits[item.id] = PlayedEdit(id: editID, played: played)
        let write = enqueueEmbyRecordWrite(.setPlayed(played), for: item, source: source)
        Task {
            do {
                try await write.value
                guard playedEdits[item.id]?.id == editID else { return }
                playedEdits[item.id]?.syncedAt = Date()
                onSuccess?()
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

    @Published private var favoriteStates: [MediaID: Bool] = [:]
    private var favoriteRevisions: [MediaID: UUID] = [:]
    private var confirmedFavorites: [MediaID: Bool] = [:]

    func effectiveFavorite(for item: MediaItem) -> Bool {
        favoriteStates[item.id] ?? item.isFavorite ?? false
    }

    /// Optimistic UI, with server writes serialized by the shared item queue.
    func setFavorite(_ favorite: Bool, for item: MediaItem, source: MediaSource,
                     completion: @escaping (String?) -> Void) {
        guard source.id == item.id.sourceID, source.kind == .emby else {
            completion(EmbyError.invalidResponse.localizedDescription)
            return
        }
        if confirmedFavorites[item.id] == nil {
            confirmedFavorites[item.id] = item.isFavorite ?? false
        }
        let revision = UUID()
        favoriteRevisions[item.id] = revision
        favoriteStates[item.id] = favorite
        let write = enqueueEmbyRecordWrite(.setFavorite(favorite), for: item, source: source)
        Task {
            do {
                try await write.value
                confirmedFavorites[item.id] = favorite
                completion(nil)
            } catch {
                if favoriteRevisions[item.id] == revision {
                    favoriteStates[item.id] = confirmedFavorites[item.id] ?? item.isFavorite ?? false
                }
                completion(error.localizedDescription)
            }
        }
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
        let entries = history
        historyPersistenceQueue.async {
            if let data = try? JSONEncoder().encode(entries) {
                UserDefaults.standard.set(data, forKey: "player.history.v1")
            }
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

    private func embyResumePosition(for item: MediaItem, source: MediaSource,
                                    serverPosition: Double?, duration: Double?) async -> Double {
        for priority in EmbyProgressPriority.sources {
            guard !Task.isCancelled else { return 0 }
            let value: Double?
            switch priority {
            case .trakt:
                // Keep Trakt in the order even when disconnected, but make no request.
                guard TraktAccountStore.shared.isConnected else { continue }
                value = await TraktAccountStore.shared.resumePosition(for: item, source: source, duration: duration ?? 0)
            case .server:
                value = serverPosition
            case .local:
                let key = item.id.sourceID.uuidString + ":" + item.id.localID
                value = UserDefaults.standard.dictionary(forKey: progressStorageKey)?[key] as? Double
            }
            if let position = EmbyProgressPriority.validPosition(value, duration: duration) { return position }
        }
        return 0
    }

    private func restoreProgressIfNeeded() {
        guard !progressRestored, canSeek else { return }
        progressRestored = true
        guard PlaybackPreferences.remembersProgress, let key = progressKey,
              let saved = UserDefaults.standard.dictionary(forKey: progressStorageKey)?[key] as? Double,
              saved > 0, saved < duration - min(2, duration * 0.05) else { return }
        seek(to: saved, resume: isPlaying)
    }

    func mediaDetails(showsDetails: Bool = false) async -> PlaybackVideoDetails? {
        if showsDetails {
            guard canShowMediaDetails, let info = core.driver?.mediaInformation else { return nil }
            let url = core.playbackURL
            let bytes = url.flatMap { $0.isFileURL ? (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize : nil }
            var technical = info.fields.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
                .map { PlaybackDetailField(label: $0.key, value: $0.value) }
            if let container = info.container, !container.isEmpty {
                technical.append(.init(label: "容器格式", value: container))
            }
            return PlaybackVideoDetails(fileName: url?.isFileURL == true ? (externalFile?.name ?? url?.lastPathComponent ?? "") : "",
                                        dimensions: info.width > 0 && info.height > 0 ? "\(info.width) × \(info.height)" : nil,
                                        byteCount: bytes.flatMap { $0 > 0 ? $0 : nil }, synopsis: nil,
                                        sourceName: source?.name ?? VesperLocalization.string("外部视频"), technical: technical,
                                        duration: info.duration.isFinite && info.duration > 0 ? info.duration : nil)
        }
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
    private func refreshTracks(using snapshot: EngineSnapshot? = nil) {
        let state = snapshot ?? core.driver?.snapshot ?? core.snapshot
        let audio = state.audio.map { PlaybackTrack(id: uiTrackID($0.id), name: $0.name, isSelected: $0.selected) }
        let subtitles = state.subtitles.map { PlaybackTrack(id: uiTrackID($0.id), name: $0.name, isSelected: $0.selected) }
        if audioTracks != audio { audioTracks = audio }
        if subtitleTracks != subtitles { subtitleTracks = subtitles }
        let selected = state.subtitles.first(where: { $0.selected }).map { uiTrackID($0.id) }
        if selectedSubtitleID != selected { selectedSubtitleID = selected }
    }
    private func updateSubtitles() {
        let state = core.snapshot
        if subtitleText != state.subtitleText { subtitleText = state.subtitleText }
        if subtitleImage !== state.subtitleImage { subtitleImage = state.subtitleImage }
    }

    private func cancelNextPreparation(discardBytes: Bool = true) {
        nextPreparation?.cancel()
        nextPreparation = nil
        nextPreparationID = nil
        preparedNext?.resource.release()
        preparedNext = nil
        if discardBytes { AetherSourcePrewarm.discard() }
    }

    private func refreshSkipMarkers() {
        guard let item = currentItem, let source, source.kind == .emby, resource != nil else { return }
        guard EmbySkipSettings.introEnabled || EmbySkipSettings.outroEnabled else {
            skipLookupTask?.cancel(); skipLookupTask = nil; skipLookupIdentity = nil; skipMarkers = .empty
            return
        }
        let resourceDuration = resource?.duration ?? 0
        let knownDuration = resourceDuration > 0 ? resourceDuration : duration
        guard knownDuration.isFinite, knownDuration > 0, knownDuration < Double(Int64.max) / 1000 else { return }
        let configuration = UserDefaults.standard.string(forKey: EmbySkipSettings.databasesKey) ?? ""
        let identity = "\(item.id.localID)|\(resource?.embyMediaSourceID ?? "")|\(Int(knownDuration))|\(configuration)"
        guard identity != skipLookupIdentity else { return }
        skipLookupTask?.cancel()
        skipLookupIdentity = identity
        skipMarkers = .empty
        let token = generation
        var target = item
        target.embyMediaSourceID = resource?.embyMediaSourceID ?? item.embyMediaSourceID
        skipLookupTask = Task { [weak self] in
            let markers = await EmbySkipLookup.shared.markers(for: target, source: source, duration: knownDuration)
            guard !Task.isCancelled, let self, self.generation == token, self.skipLookupIdentity == identity else { return }
            self.skipMarkers = markers
            self.log("[IntroOutro] 播放器应用标记，片头段数=\(markers.intros.count)，片尾起点=\(markers.creditsStart.map { String($0) } ?? "无")，时长=\(knownDuration)")
            self.skipLookupTask = nil
        }
    }

    private var nextEpisodePreloadPosition: Double {
        let fraction = Double(EmbyPreloadCacheSettings.nextPercent) / 100
        guard UserDefaults.standard.bool(forKey: EmbySkipSettings.bodyPreloadKey) else { return duration * fraction }
        return skipMarkers.preloadPosition(duration: duration, fraction: fraction,
                                          introEnabled: EmbySkipSettings.introEnabled, outroEnabled: EmbySkipSettings.outroEnabled)
    }

    /// Automatic actions never run while scrubbing, paused, loading or on a non-Emby source.
    private func applySkipMarkers() -> Bool {
        guard source?.kind == .emby, isPlaying, !isLoading, !isSeeking, !seekInFlight, duration > 0 else { return false }
        if EmbySkipSettings.introEnabled, canSeek,
           let interval = skipMarkers.intros.first(where: { currentTime >= $0.start && currentTime < $0.end && !skippedIntroEnds.contains($0.end) }),
           interval.end < duration {
            skippedIntroEnds.insert(interval.end)
            log("[IntroOutro] 自动跳过片头，当前位置=\(currentTime)，区间=\(interval.start)-\(interval.end)，目标=\(interval.end)")
            seek(to: interval.end, resume: true)
            automaticSkipNotice = AutomaticSkipNotice(kind: .intro)
        }
        if EmbySkipSettings.outroEnabled, !skippedCredits,
           hasNext || canSeek,
           let start = skipMarkers.creditsStart, start < duration, currentTime >= start {
            skippedCredits = true
            if hasNext {
                log("[IntroOutro] 自动跳过片尾，当前位置=\(currentTime)，片尾起点=\(start)，切换下一集")
                next()
            } else {
                let target = max(0, duration - 1)
                log("[IntroOutro] 自动跳过片尾，当前位置=\(currentTime)，片尾起点=\(start)，无下一集，目标=\(target)")
                seek(to: target, resume: true)
            }
            automaticSkipNotice = AutomaticSkipNotice(kind: .outro)
            return true
        }
        return false
    }

    private func prepareNextEpisodeIfNeeded() {
        if UserDefaults.standard.bool(forKey: EmbySkipSettings.bodyPreloadKey), skipLookupTask != nil { return }
        guard isPlaying, !isLoading, !isSeeking, currentEngine == .aether,
              duration > 0, currentTime >= nextEpisodePreloadPosition,
              let source, source.kind == .emby, let item = currentItem, item.embyItemType == "Episode",
              let index = queue.firstIndex(where: { $0.id == item.id }), index + 1 < queue.count,
              queue[index + 1].embyItemType == "Episode",
              attemptedNextForGeneration != generation,
              Date().timeIntervalSince(lastNextPolicyAttempt) >= 5 else { return }
        lastNextPolicyAttempt = Date()
        attemptedNextForGeneration = generation
        let target = queue[index + 1]
        let token = generation
        nextPreparationID = target.id
        nextPreparation = Task { [weak self] in
            guard let self else { return }
            guard await EmbyPreloadCacheSettings.allowsNextEpisode(), !Task.isCancelled,
                  self.generation == token else {
                if self.generation == token { self.attemptedNextForGeneration = nil }
                return
            }
            var resolved: ResolvedPlaybackResource?
            var retained = false
            defer { if !retained { resolved?.release() } }
            do {
                let currentSourceID = self.resource?.embyMediaSourceID ?? item.embyMediaSourceID
                let current = try? await EmbyRepository.shared.detailMetadata(for: item, source: source)
                try Task.checkCancellation()
                let metadata = try await EmbyRepository.shared.detailMetadata(for: target, source: source)
                let currentVersion = current?.mediaVersions.first(where: { $0.id == currentSourceID })
                    ?? current?.mediaVersions.first
                let best = EmbyVersionMatcher.closest(to: currentVersion, in: metadata.mediaVersions)
                var selected = target
                selected.embyMediaSourceID = best?.id
                let resource = try await PlaybackResourceResolver().resolve(selected, source: source)
                resolved = resource
                selected.embyMediaSourceID = resource.embyMediaSourceID ?? selected.embyMediaSourceID
                try Task.checkCancellation()
                guard resource.url.pathExtension.lowercased() != "m3u8" else { return }
                // Keep speculative reads small; this is separate from the playing session budget.
                let budget = min(8 * 1024 * 1024, await EmbyPreloadCacheSettings.currentLimitBytes())
                let policy = Task { @MainActor in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        let allowed = await EmbyPreloadCacheSettings.allowsNextEpisode()
                        guard !Task.isCancelled, self.generation == token else { return }
                        guard allowed else { self.cancelNextPreparation(); return }
                    }
                }
                defer { policy.cancel() }
                let warmed = await AetherSourcePrewarm.prepare(url: resource.url, headers: resource.headers, byteBudget: budget)
                try Task.checkCancellation()
                guard warmed, self.generation == token, self.nextPreparationID == target.id else { return }
                self.preparedNext = (selected, source.id, resource)
                retained = true
                // Keep the warm until consumed, stopped, replaced, or disallowed by network policy.
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                    guard self.generation == token else { return }
                    let allowed = await EmbyPreloadCacheSettings.allowsNextEpisode()
                    guard !Task.isCancelled, self.generation == token else { return }
                    guard allowed else { self.cancelNextPreparation(); return }
                }
            } catch {
                // Preloading is best-effort; playback errors belong only to the active video.
                if self.generation == token { self.cancelNextPreparation() }
            }
        }
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

    private func refreshPlaybackSubtitle(for item: MediaItem, source: MediaSource?, token: UUID) {
        playbackSubtitleTask?.cancel()
        playbackSubtitleTask = nil
        // Emby version names are file labels, not the episode's display context.
        playbackSubtitle = item.embyItemType == "Movie" ? item.title : (item.embyItemType == nil ? item.subtitle : nil)
        guard item.embyItemType == "Episode", let source, source.kind == .emby else { return }
        playbackSubtitleTask = Task { [weak self] in
            guard let metadata = try? await EmbyRepository.shared.detailMetadata(for: item, source: source),
                  !Task.isCancelled else { return }
            var parts: [String] = []
            if let series = metadata.series {
                parts.append(series.title)
                var count = series.embyPresentation?.seasonCount
                if count == nil {
                    count = try? await EmbyRepository.shared.seriesSeasonCount(for: series, source: source)
                }
                guard !Task.isCancelled else { return }
                if (count ?? 0) > 1 || (metadata.seasonNumber ?? 0) > 1,
                   let season = metadata.seasonNumber {
                    parts.append(season == 0 ? VesperLocalization.string("特别篇") : VesperLocalization.localized("第\(season)季"))
                }
            }
            if let episode = metadata.episodeNumber {
                parts.append(VesperLocalization.localized("第\(episode)集"))
            }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.playbackSubtitle = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    func stop() {
        hasLoadedMedia = false
        playbackSubtitleTask?.cancel()
        playbackSubtitleTask = nil
        playbackSubtitle = nil
        traktReporter.finish()
        saveProgress()
        recordPlaybackHistory()
        cancelNextPreparation()
        skipLookupTask?.cancel()
        skipLookupTask = nil
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
        downloadSpeedSampler = DownloadSpeedSampler()
        downloadBytesPerSecond = nil
        pipStartTask?.cancel(); pipStartTask = nil
        decoderChange?.cancel(); decoderChange = nil; requestedDecoder = nil
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
        bufferedRanges = []
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
        value.subtitleFontSize = subtitleSize
        value.subtitleDelay = subtitleDelay
        value.requestHeaders = resource?.headers ?? [:]
        value.externalSubtitles = resource?.externalSubtitles ?? []
        return value
    }
    private var lastNowPlayingUpdate = Date.distantPast
    private var lastNowPlayingRate: Float?
    private var lastNowPlayingTitle: String?
    private var lastNowPlayingDuration: TimeInterval = -1
    private var lastNowPlayingPosition: TimeInterval = -1
    private var lastSlowStateLog: TimeInterval = 0

    private func syncCoreState() {
        let started = ProcessInfo.processInfo.systemUptime
        var checkpoint = started
        var slowSteps: [String] = []
        func measure(_ name: String) {
            let now = ProcessInfo.processInfo.systemUptime
            let milliseconds = (now - checkpoint) * 1000
            if milliseconds >= 4 { slowSteps.append("\(name)=\(Int(milliseconds))ms") }
            checkpoint = now
        }
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if elapsed > 0.016, started - lastSlowStateLog > 5 {
                lastSlowStateLog = started
                log("[Performance] 播放状态同步耗时 \(Int(elapsed * 1000))ms，\(slowSteps.joined(separator: ", "))")
            }
        }
        let state = core.snapshot
        if !hasLoadedMedia && !core.isTransitioning {
            switch state.phase {
            case .playing, .paused, .ended: hasLoadedMedia = true
            default: break
            }
        }
        // Lifecycle notifications and engine teardown completion can arrive in
        // either order. Also check the first fresh snapshot after foreground.
        if state.requiresForegroundReload, restoreReleasedAetherSession(resume: core.requestedAutoplay) { return }
        let view = core.view
        if videoView !== view { videoView = view }
        let engine: PlaybackEngine = core.engineID == .aether ? .aether : .vlc
        if currentEngine != engine { currentEngine = engine }
        if let actual = state.actualDecoder {
            let decoder: PlaybackDecoder = actual == .software ? .software : .hardware
            if decoder != currentDecoder, requestedDecoder == nil, !core.isTransitioning {
                playbackTransitionNotice = .init(message: "已自动切换至\(decoder.title)")
            }
            if currentDecoder != decoder { currentDecoder = decoder }
        }
        let loading = core.isTransitioning || state.phase == .loading
        if isLoading != loading { isLoading = loading }
        let playing = state.phase == .playing
        if isPlaying != playing { isPlaying = playing }
        if appIsInBackground && !PlaybackPreferences.backgroundEnabled && isPlaying { core.pause() }
        if !state.requiresForegroundReload && !isSeeking && !core.isTransitioning {
            if let landing = seekLanding {
                if abs(state.time - landing.time) < 1.5 || Date() >= landing.deadline { seekLanding = nil; currentTime = max(0, state.time) }
            } else {
                let nextTime = state.time.isFinite ? max(0, state.time) : 0
                if abs(currentTime - nextTime) > 0.01 { currentTime = nextTime }
            }
        }
        if !state.requiresForegroundReload && (!isLoading || state.duration > 0) {
            let engineDuration = state.duration.isFinite ? max(0, state.duration) : 0
            let total = engineDuration > 0 ? engineDuration : (resource?.duration ?? 0)
            if duration != total { duration = total }
        }
        let buffered = state.buffered.isFinite ? max(currentTime, state.buffered) : currentTime
        if bufferedTime != buffered { bufferedTime = buffered }
        if bufferedRanges != state.bufferedRanges { bufferedRanges = state.bufferedRanges }
        if case .failed(let message) = state.phase { errorMessage = message; isLoading = false }
        if state.phase == .ended {
            currentTime = duration; saveProgress(); recordPlaybackHistory()
            embySession?.finish()
        }
        measure("timeline")
        embySession?.update(position: currentTime, paused: !isPlaying, rate: playbackRate,
                            remembersProgress: PlaybackPreferences.remembersProgress,
                            ready: !isLoading && (state.phase == .playing || state.phase == .paused || state.phase == .ended))
        traktReporter.update(item: currentItem, source: source, position: currentTime, duration: duration,
                             playing: isPlaying, ended: state.phase == .ended,
                             ready: !isLoading && !isSeeking && progressRestored &&
                                (state.phase == .playing || state.phase == .paused || state.phase == .ended))
        measure("serverProgress")
        refreshSkipMarkers()
        if applySkipMarkers() { return }
        prepareNextEpisodeIfNeeded()
        measure("skipAndPreload")
        // Reuse this poll's snapshot instead of reading the engine a second time.
        refreshTracks(using: state); updateSubtitles(); configurePictureInPicture()
        measure("tracksAndPiP")
        // SwiftVLC retains its native AVKit delegate; consume its observable PiP state.
        if isPictureInPicturePossible != state.pipPossible { isPictureInPicturePossible = state.pipPossible }
        if state.pipActive != previouslyActivePiP {
            previouslyActivePiP = state.pipActive
            isPictureInPictureActive = state.pipActive
            if state.pipActive { isPresented = false }
            else if !restoringPiP && !isPresented && !(appIsInBackground && PlaybackPreferences.backgroundEnabled && PlaybackPreferences.backgroundMode == "audio") { pause() }
        }
        restoreProgressIfNeeded()
        if Date().timeIntervalSince(lastProgressSave) >= 5 && !isSeeking { saveProgress() }
        if isPlaying && !isSeeking && Date().timeIntervalSince(lastHistorySave) >= 5 { recordPlaybackHistory() }
        measure("persistProgress")
        if UIApplication.shared.isIdleTimerDisabled != isPlaying {
            UIApplication.shared.isIdleTimerDisabled = isPlaying
        }
        let nowPlayingRate: Float = isPlaying ? playbackRate : 0
        let nowPlayingChanged = lastNowPlayingRate != nowPlayingRate
            || lastNowPlayingTitle != currentItem?.title || lastNowPlayingDuration != duration
            || abs(currentTime - lastNowPlayingPosition) > 2
        if !core.isTransitioning && (nowPlayingChanged || (isPlaying && Date().timeIntervalSince(lastNowPlayingUpdate) >= 1)) {
            lastNowPlayingUpdate = Date()
            lastNowPlayingRate = nowPlayingRate
            lastNowPlayingTitle = currentItem?.title
            lastNowPlayingDuration = duration
            lastNowPlayingPosition = currentTime
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyTitle] = currentItem?.title
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
        measure("nowPlaying")
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
    var duration: Double? = nil
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

struct PlaybackHistoryEntry: Identifiable, Codable, Sendable {
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
