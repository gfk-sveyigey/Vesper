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

    private var layer: KSPlayerLayer?
    private var resource: ResolvedPlaybackResource?
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private var queue: [MediaItem] = []
    private var source: MediaSource?

    var hasNext: Bool {
        guard let currentItem, let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return false }
        return index + 1 < queue.count
    }
    var canControl: Bool { layer != nil && errorMessage == nil }
    var canSeek: Bool { canControl && duration > 0 && layer?.player.seekable == true }

    func play(_ item: MediaItem, in source: MediaSource, queue: [MediaItem]) {
        self.queue = queue
        self.source = source
        isPresented = true
        load(item, source: source)
    }

    private func load(_ item: MediaItem, source: MediaSource) {
        request?.cancel()
        generation = UUID()
        let token = generation
        tearDownPlayer()
        currentItem = item
        currentTime = 0
        duration = 0
        errorMessage = nil
        isLoading = true
        request = Task { [weak self] in
            do {
                let resolved = try await PlaybackResourceResolver().resolve(item, source: source)
                guard let self, !Task.isCancelled, self.generation == token else {
                    resolved.release()
                    return
                }
                self.resource = resolved
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                let options = KSOptions()
                let player = KSPlayerLayer(url: resolved.url, isAutoPlay: false, options: options)
                self.layer = player
                player.delegate = self
                self.videoView = player.player.view
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

    func seek(to time: TimeInterval) {
        guard canSeek, time.isFinite else { return }
        let target = min(max(0, time), duration)
        layer?.seek(time: target, autoPlay: isPlaying) { _ in }
        currentTime = target
    }

    func next() {
        guard hasNext, let source, let currentItem,
              let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return }
        load(queue[index + 1], source: source)
    }

    func retry() {
        guard let currentItem, let source else { return }
        load(currentItem, source: source)
    }

    func stop() {
        request?.cancel()
        request = nil
        generation = UUID()
        tearDownPlayer()
        currentItem = nil
        source = nil
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
        isPlaying = false
    }

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard layer === self.layer else { return }
        videoView = layer.player.view
        isPlaying = state.isPlaying
        isLoading = state == .preparing || state == .buffering
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
