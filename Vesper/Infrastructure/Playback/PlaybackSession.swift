import AVFoundation
import Combine
@preconcurrency import KSPlayer
import UIKit

/// A single app-owned session. Tabs and player presentation never own or reset
/// the decoder. KSPlayer APIs are contained here, outside navigation code.
@MainActor
final class PlaybackSession: ObservableObject, KSPlayerLayerDelegate {
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
    private let subtitleModel = SubtitleModel()

    private var layer: KSPlayerLayer?
    private var resource: ResolvedPlaybackResource?
    private var request: Task<Void, Never>?
    private var generation = UUID()
    @Published private(set) var queue: [MediaItem] = []
    private var source: MediaSource?
    private var externalFile: IncomingVideo?

    var hasNext: Bool {
        guard let currentItem, let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return false }
        return index + 1 < queue.count
    }
    var canControl: Bool { layer != nil && errorMessage == nil }
    var canSeek: Bool { canControl && duration > 0 && layer?.player.seekable == true }

    func play(_ item: MediaItem, in source: MediaSource, queue: [MediaItem]) {
        externalFile = nil
        self.queue = queue
        self.source = source
        isPresented = true
        load(item, source: source)
    }

    func playExternal(_ file: IncomingVideo) {
        externalFile = file
        source = nil
        queue = []
        let item = MediaItem(id: MediaID(sourceID: file.id, localID: file.name),
                             title: file.name, resource: nil)
        isPresented = true
        load(item, source: nil)
    }

    private func load(_ item: MediaItem, source: MediaSource?) {
        request?.cancel()
        generation = UUID()
        let token = generation
        tearDownPlayer()
        currentItem = item
        currentTime = 0
        duration = 0
        errorMessage = nil
        isLoading = true
        let external = externalFile
        request = Task { [weak self] in
            do {
                let resolved: ResolvedPlaybackResource
                if let external {
                    resolved = ResolvedPlaybackResource(url: external.url, externalAccess: external.access)
                } else if let source {
                    resolved = try await PlaybackResourceResolver().resolve(item, source: source)
                } else {
                    throw PlaybackFailure.missingFile
                }
                guard let self, !Task.isCancelled, self.generation == token else {
                    resolved.release()
                    return
                }
                self.resource = resolved
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                let options = KSOptions()
                options.startPlayRate = self.playbackRate
                options.isSeekImageSubtitle = true
                let player = KSPlayerLayer(url: resolved.url, isAutoPlay: false, options: options)
                self.layer = player
                player.delegate = self
                self.videoView = player.player.view
                player.player.contentMode = self.fillsScreen ? .scaleAspectFill : .scaleAspectFit
                player.play()
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.tearDownPlayer()
                self.isLoading = false
                self.errorMessage = error.localizedDescription
                self.log("加载失败：\(error.localizedDescription)")
            }
        }
    }

    func togglePlayback() {
        guard let layer, errorMessage == nil else { return }
        if isPlaying { layer.pause() } else { layer.play() }
    }

    func pause() { layer?.pause() }

    func seek(to time: TimeInterval, resume: Bool? = nil) {
        guard canSeek, time.isFinite, let layer else { return }
        let target = min(max(0, time), duration)
        let token = generation
        isSeeking = true
        layer.seek(time: target, autoPlay: resume ?? isPlaying) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.isSeeking = false
                self.updateSubtitles()
            }
        }
        currentTime = target
    }

    func setPlaybackRate(_ rate: Float) {
        guard [Float(0.5), 0.75, 1, 1.25, 1.5, 2].contains(rate) else { return }
        playbackRate = rate
        layer?.player.playbackRate = rate
    }

    func toggleFill() {
        fillsScreen.toggle()
        layer?.player.contentMode = fillsScreen ? .scaleAspectFill : .scaleAspectFit
    }

    func playQueued(_ item: MediaItem) {
        guard let source, queue.contains(where: { $0.id == item.id }) else { return }
        load(item, source: source)
    }

    func selectAudio(_ id: Int32) {
        guard let player = layer?.player,
              let track = player.tracks(mediaType: .audio).first(where: { $0.trackID == id }) else { return }
        player.select(track: track)
        refreshTracks()
    }

    func selectSubtitle(_ id: Int32?) {
        guard let player = layer?.player else { return }
        subtitleModel.selectedSubtitleInfo = nil
        if let id, let track = player.tracks(mediaType: .subtitle).first(where: { $0.trackID == id }) {
            player.select(track: track)
            subtitleModel.selectedSubtitleInfo = player.subtitleDataSouce?.infos.first { $0.subtitleID == String(id) }
        } else {
            for track in player.tracks(mediaType: .subtitle) { track.isEnabled = false }
        }
        selectedSubtitleID = id
        updateSubtitles()
        refreshTracks()
    }

    private func refreshTracks() {
        guard let player = layer?.player else { return }
        let audio = player.tracks(mediaType: .audio).map { PlaybackTrack(id: $0.trackID, name: $0.name, isSelected: $0.isEnabled) }
        let subtitles = player.tracks(mediaType: .subtitle).map { PlaybackTrack(id: $0.trackID, name: $0.name, isSelected: $0.trackID == selectedSubtitleID) }
        if audioTracks != audio { audioTracks = audio }
        if subtitleTracks != subtitles { subtitleTracks = subtitles }
    }

    private func updateSubtitles() {
        _ = subtitleModel.subtitle(currentTime: currentTime)
        let text = subtitleModel.parts.compactMap { $0.text?.string }.joined(separator: "\n")
        if subtitleText != text { subtitleText = text }
        let image = subtitleModel.parts.compactMap(\.image).first
        if subtitleImage !== image { subtitleImage = image }
    }

    func next() {
        guard hasNext, let source, let currentItem,
              let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return }
        load(queue[index + 1], source: source)
    }

    func retry() {
        guard let currentItem else { return }
        load(currentItem, source: source)
    }

    func stop() {
        request?.cancel()
        request = nil
        generation = UUID()
        tearDownPlayer()
        currentItem = nil
        source = nil
        externalFile = nil
        queue = []
        currentTime = 0
        duration = 0
        isLoading = false
        errorMessage = nil
        isPresented = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tearDownPlayer() {
        layer?.delegate = nil
        layer?.stop()
        videoView?.removeFromSuperview()
        videoView = nil
        layer = nil
        resource?.release()
        resource = nil
        subtitleModel.selectedSubtitleInfo = nil
        _ = subtitleModel.subtitle(currentTime: 0)
        subtitleText = ""
        subtitleImage = nil
        selectedSubtitleID = nil
        audioTracks = []
        subtitleTracks = []
        bufferedTime = 0
        isSeeking = false
        isPlaying = false
    }

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard layer === self.layer else { return }
        videoView = layer.player.view
        isPlaying = state.isPlaying
        isLoading = state == .preparing || state == .buffering
        if state == .readyToPlay {
            layer.player.playbackRate = playbackRate
            layer.player.contentMode = fillsScreen ? .scaleAspectFill : .scaleAspectFit
            for track in layer.player.tracks(mediaType: .subtitle) { track.isEnabled = false }
        }
        refreshTracks()
        if state == .playedToTheEnd {
            currentTime = duration
            UIApplication.shared.isIdleTimerDisabled = false
        }
        log("状态：\(state)")
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard layer === self.layer else { return }
        self.currentTime = currentTime.isFinite ? max(0, currentTime) : 0
        duration = totalTime.isFinite ? max(0, totalTime) : 0
        let playable = layer.player.playableTime
        bufferedTime = playable.isFinite ? min(duration, max(currentTime, playable)) : currentTime
        refreshTracks()
        updateSubtitles()
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard layer === self.layer else { return }
        isPlaying = false
        isLoading = false
        if let error {
            errorMessage = error.localizedDescription
            UIApplication.shared.isIdleTimerDisabled = false
            log("播放失败：\(error.localizedDescription)")
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}

    private func log(_ message: String) {
        AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [Playback] \(message)")
    }
}

struct PlaybackTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
    let isSelected: Bool
}
