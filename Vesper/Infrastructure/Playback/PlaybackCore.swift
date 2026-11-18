import Foundation
import UIKit
import AVKit
import PlaybackContracts
import VesperAetherBridge
import VesperVLCBridge

/// Server fallback is supplied only for an authenticated server-backed item.
/// Local/Photos sources must never be silently uploaded to a server.
struct TranscodedPlaybackResource: Sendable {
    let url: URL
    /// Original-media time represented by time zero of the returned stream.
    let timelineOffset: Double
    let originalDuration: Double
}

@MainActor protocol PlaybackTranscodingProvider: AnyObject {
    func transcode(position: Double) async throws -> TranscodedPlaybackResource
    func stopTranscoding() async
}

/// The UI talks only to this owner. Engine creation, retirement and failover
/// share one serial task chain; cancellation never starts a second live decoder.
@MainActor final class PlaybackCore {
    private(set) var driver: (any PlaybackDriver)?
    private(set) var engineID: EngineID = .aether
    private(set) var snapshot = EngineSnapshot()
    private(set) var isTransitioning = false
    var onChange: (() -> Void)?
    var restoreUI: ((@escaping (Bool) -> Void) -> Void)?
    var log: ((String) -> Void)?
    weak var transcodingProvider: (any PlaybackTranscodingProvider)?
    private var transition: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var token = UUID()
    private var url: URL?
    private var configuration = EngineConfiguration()
    private var attempted: Set<EngineID> = []
    private var hasTriedServer = false
    private var lastError: Error?
    private var timelineOffset: Double = 0
    private var originalDuration: Double = 0
    var view: UIView? { driver?.view }
    var nativePiPController: AVPictureInPictureController? { driver?.nativePiPController }

    func load(_ url: URL, preferred: EngineID, configuration: EngineConfiguration, audio: EngineTrack? = nil, subtitle: EngineTrack? = nil) async throws {
        let barrier = shutdown()
        let generation = UUID(); token = generation
        self.url = url; self.configuration = configuration
        attempted = []; hasTriedServer = false; lastError = nil
        timelineOffset = 0; originalDuration = 0
        engineID = preferred
        isTransitioning = true; snapshot.phase = .loading; onChange?()
        let operation = Task { [weak self] in
            await barrier.value
            guard let self, self.token == generation, !Task.isCancelled else { return }
            await self.open(url, preferred: preferred, generation: generation, audio: audio, subtitle: subtitle, subtitlesOff: subtitle == nil)
        }
        transition = operation
        await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        if let lastError { throw lastError }
    }
    /// Return a retirement barrier so file access is kept alive until all native
    /// readers and pending open/seek work stop. Never await yourself in this chain.
    @discardableResult func shutdown() -> Task<Void, Never> {
        token = UUID(); monitor?.cancel(); monitor = nil
        let pending = transition; pending?.cancel()
        let seeking = seekTask; seeking?.cancel(); seekTask = nil
        let retiring = driver; driver = nil
        snapshot = EngineSnapshot(); isTransitioning = false
        let server = transcodingProvider
        let task = Task {
            await pending?.value
            await seeking?.value
            await retiring?.shutdown()
            await server?.stopTranscoding()
        }
        transition = task
        return task
    }
    private func open(_ url: URL, preferred: EngineID, generation: UUID,
                      audio: EngineTrack?, subtitle: EngineTrack?, subtitlesOff: Bool) async {
        var order = [preferred] + EngineID.allCases.filter { $0 != preferred }
        order.removeAll { attempted.contains($0) }
        for id in order {
            guard token == generation, !Task.isCancelled else { return }
            attempted.insert(id); engineID = id
            let candidate: any PlaybackDriver = id == .aether ? AetherDriver() : VLCDriver()
            candidate.restoreUI = { [weak self] completion in
                guard let restore = self?.restoreUI else { completion(false); return }; restore(completion)
            }
            driver = candidate
            snapshot.phase = .loading; onChange?()
            do {
                log?("打开引擎 \(id.rawValue)，position=\(configuration.position)")
                var localConfiguration = configuration
                localConfiguration.position = max(0, configuration.position - timelineOffset)
                try await candidate.load(url: url, configuration: localConfiguration)
                try Task.checkCancellation()
                guard token == generation else { await candidate.shutdown(); return }
                localConfiguration = self.configuration
                localConfiguration.position = max(0, self.configuration.position - timelineOffset)
                candidate.configure(localConfiguration)
                if localConfiguration.autoplay { try candidate.play() } else { candidate.pause() }
                let state = candidate.snapshot
                if let selected = match(audio, in: state.audio) { candidate.selectAudio(selected.id) }
                if subtitlesOff { candidate.selectSubtitle(nil) }
                else if let selected = match(subtitle, in: state.subtitles) { candidate.selectSubtitle(selected.id) }
                else { candidate.selectSubtitle(nil) }
                isTransitioning = false; lastError = nil
                poll(generation: generation)
                return
            } catch {
                // Fully retire failed instances before trying the other engine.
                log?("引擎 \(id.rawValue) 失败：\(error.localizedDescription)")
                await candidate.shutdown()
                if driver === candidate { driver = nil }
                guard token == generation, !Task.isCancelled else { return }
                lastError = error
            }
        }
        // No recursive failover loop. Each engine and server tier is tried once.
        if !hasTriedServer, let server = transcodingProvider {
            hasTriedServer = true
            do {
                let transcode = try await server.transcode(position: configuration.position)
                guard token == generation, !Task.isCancelled else { return }
                guard transcode.timelineOffset.isFinite, transcode.timelineOffset >= 0,
                      transcode.originalDuration.isFinite, transcode.originalDuration > transcode.timelineOffset else {
                    throw PlaybackCoreError.failed("服务器返回了无效的转码时间轴。")
                }
                timelineOffset = transcode.timelineOffset
                originalDuration = transcode.originalDuration
                self.url = transcode.url
                attempted = []
                await open(transcode.url, preferred: .aether, generation: generation, audio: audio, subtitle: subtitle, subtitlesOff: subtitlesOff)
                return
            } catch { lastError = error }
        }
        guard token == generation, !Task.isCancelled else { return }
        isTransitioning = false
        snapshot.phase = .failed(lastError?.localizedDescription ?? "所有播放引擎均无法播放此视频。")
        onChange?()
    }
    private func match(_ old: EngineTrack?, in tracks: [EngineTrack]) -> EngineTrack? {
        guard let old else { return nil }
        // IDs are engine-local. Match semantics, never an unrelated reused ID.
        return tracks.first { $0.language == old.language && $0.codec == old.codec && $0.name == old.name }
            ?? tracks.first { old.language != nil && $0.language == old.language && $0.codec == old.codec }
            ?? tracks.first { $0.name == old.name && !old.name.isEmpty }
    }
    private func poll(generation: UUID) {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.token == generation, let driver = self.driver else { return }
                let previous = self.snapshot
                self.snapshot = driver.snapshot
                if self.timelineOffset > 0 || self.originalDuration > 0 {
                    self.snapshot.time += self.timelineOffset
                    self.snapshot.buffered += self.timelineOffset
                    self.snapshot.duration = self.originalDuration
                }
                if case .failed(let message) = self.snapshot.phase {
                    self.configuration.position = previous.time
                    if previous.phase == .playing { self.configuration.autoplay = true }
                    else if previous.phase == .paused { self.configuration.autoplay = false }
                    let audio = previous.audio.first { $0.selected }
                    let subtitle = previous.subtitles.first { $0.selected }
                    self.isTransitioning = true
                    self.snapshot.phase = .loading; self.onChange?()
                    self.log?("播放中回退：\(message)")
                    let pending = self.transition
                    let operation = Task { [weak self] in
                        await pending?.value
                        let seeking = self?.seekTask
                        seeking?.cancel()
                        await seeking?.value
                        await driver.shutdown()
                        guard let self, self.token == generation, !Task.isCancelled, let url = self.url else { return }
                        if self.driver === driver { self.driver = nil }
                        await self.open(url, preferred: .aether, generation: generation, audio: audio, subtitle: subtitle, subtitlesOff: subtitle == nil)
                    }
                    self.transition = operation
                    return
                }
                self.onChange?()
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
        }
    }
    func waitUntilRetired() async { await transition?.value }
    func configure(_ value: EngineConfiguration) {
        configuration = value
        var local = value; local.position = max(0, value.position - timelineOffset)
        driver?.configure(local)
    }
    func play() { configuration.autoplay = true; do { try driver?.play() } catch { log?(error.localizedDescription) } }
    func pause() { configuration.autoplay = false; driver?.pause() }
    func seek(to seconds: Double, resume: Bool, completion: @escaping (Bool) -> Void) {
        guard let driver, !isTransitioning else { completion(false); return }
        guard seconds >= timelineOffset else {
            // A start-trimmed server stream cannot seek into its omitted prefix.
            // The provider must reopen a new stream before accepting that seek.
            completion(false); return
        }
        let generation = token
        let localSeconds = seconds - timelineOffset
        let pending = seekTask
        seekTask = Task { [weak self] in
            do {
                await pending?.value
                try Task.checkCancellation()
                try await driver.seek(to: localSeconds)
                try Task.checkCancellation()
                guard let self, self.token == generation else { completion(false); return }
                if resume { self.play() } else { self.pause() }
                completion(true)
            } catch { completion(false) }
        }
    }
    func selectAudio(_ id: String) { driver?.selectAudio(id) }
    func selectSubtitle(_ id: String?) { driver?.selectSubtitle(id) }
    func startPiP() { driver?.startPiP() }
    func stopPiP() { driver?.stopPiP() }
    func setPiPActive(_ active: Bool) { driver?.setPiPActive(active) }
}
