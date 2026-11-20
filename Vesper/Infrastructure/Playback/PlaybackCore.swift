import Foundation
import Network
import UIKit
import AVKit
import PlaybackContracts
import VesperAetherBridge
import VesperVLCBridge

/// Server fallback is supplied only for an authenticated server-backed item.
/// Local/Photos sources must never be silently uploaded to a server.
struct TranscodedPlaybackResource: Sendable {
    let url: URL
    var headers: [String: String] = [:]
    var bitRate: Double? = nil
    /// Original-media time represented by time zero of the returned stream.
    let timelineOffset: Double
    let originalDuration: Double
}

@MainActor protocol PlaybackTranscodingProvider: AnyObject {
    func transcode(position: Double, forceVideoTranscode: Bool) async throws -> TranscodedPlaybackResource
    func stopTranscoding() async
    func didActivateTranscoding()
}

/// The UI talks only to this owner. Engine creation, retirement and failover
/// share one serial task chain. Decoder switching stages a muted candidate.
@MainActor final class PlaybackCore {
    private(set) var driver: (any PlaybackDriver)?
    private(set) var engineID: EngineID = .aether
    private(set) var snapshot = EngineSnapshot()
    private(set) var isTransitioning = false
    var onChange: (() -> Void)?
    var restoreUI: ((@escaping (Bool) -> Void) -> Void)?
    var log: ((String) -> Void)?
    var onEngineFallback: ((EngineID, EngineID) -> Void)?
    weak var transcodingProvider: (any PlaybackTranscodingProvider)?
    private var transition: Task<Void, Never>?
    private var decoderPreparation: Task<DecodePreference?, Error>?
    private var monitor: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var token = UUID()
    private var url: URL?
    private var configuration = EngineConfiguration()
    private var attempted: Set<EngineID> = []
    private var hasTriedServer = false
    private var serverAttemptCount = 0
    private var lastError: Error?
    private var timelineOffset: Double = 0
    private var originalDuration: Double = 0
    var view: UIView? { driver?.view }
    var nativePiPController: AVPictureInPictureController? { driver?.nativePiPController }

    func load(_ url: URL, preferred: EngineID, configuration: EngineConfiguration, audio: EngineTrack? = nil,
              subtitle: EngineTrack? = nil, server: (any PlaybackTranscodingProvider)? = nil) async throws {
        let barrier = shutdown()
        transcodingProvider = server
        let generation = UUID(); token = generation
        self.url = url; self.configuration = configuration
        attempted = []; hasTriedServer = false; lastError = nil
        serverAttemptCount = 0
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
        let preparing = decoderPreparation; preparing?.cancel(); decoderPreparation = nil
        let retiring = driver; driver = nil
        snapshot = EngineSnapshot(); isTransitioning = false
        let server = transcodingProvider
        transcodingProvider = nil
        let task = Task {
            await pending?.value
            _ = try? await preparing?.value
            await seeking?.value
            await retiring?.shutdown()
            await server?.stopTranscoding()
        }
        transition = task
        return task
    }
    /// Stage a paused, muted decoder while the active driver continues playing.
    /// Failure leaves the active player and server session untouched.
    func switchDecoder(to decoder: DecodePreference) async throws -> DecodePreference? {
        guard engineID != .vlc, decoderPreparation == nil, !isTransitioning,
              let active = driver, let url, snapshot.seekable,
              snapshot.phase == .playing || snapshot.phase == .paused,
              !snapshot.pipActive else {
            throw PlaybackCoreError.failed("当前播放状态暂不支持后台切换解码")
        }
        let generation = token
        let id = engineID
        let operation = Task { @MainActor [weak self] () throws -> DecodePreference? in
            guard let self else { throw CancellationError() }
            let candidate: any PlaybackDriver = id == .aether ? AetherDriver() : VLCDriver()
            candidate.restoreUI = active.restoreUI
            do {
                var preparation = self.configuration
                preparation.decoder = decoder
                preparation.position = max(0, self.snapshot.time - self.timelineOffset)
                preparation.autoplay = false
                preparation.muted = true
                preparation.automaticPiP = false
                try await candidate.load(url: url, configuration: preparation)
                try Task.checkCancellation()
                guard self.token == generation, self.driver === active, !self.isTransitioning,
                      !active.snapshot.pipActive else { throw CancellationError() }
                if let actual = candidate.snapshot.actualDecoder, actual != decoder {
                    throw PlaybackCoreError.failed("视频不支持所选解码方式")
                }
                // Opening may take seconds; align to the OLD driver's latest local time.
                let target = max(0, active.snapshot.time)
                try await candidate.seek(to: target)
                try Task.checkCancellation()
                guard self.token == generation, self.driver === active, !self.isTransitioning,
                      !active.snapshot.pipActive, !self.snapshot.pipActive,
                      active.snapshot.phase == .playing || active.snapshot.phase == .paused,
                      candidate.snapshot.phase == .paused || candidate.snapshot.phase == .playing,
                      abs(candidate.snapshot.time - active.snapshot.time) < 1.5 else {
                    throw PlaybackCoreError.failed("解码切换未能对齐当前播放位置")
                }
                let audio = active.snapshot.audio.first { $0.selected }
                let subtitle = active.snapshot.subtitles.first { $0.selected }
                if let selected = self.match(audio, in: candidate.snapshot.audio) { candidate.selectAudio(selected.id) }
                candidate.selectSubtitle(subtitle.flatMap { self.match($0, in: candidate.snapshot.subtitles)?.id })
                var applied = self.configuration
                applied.decoder = decoder
                applied.position = target
                active.pause()
                candidate.configure(applied)
                do {
                    if applied.autoplay { try candidate.play() } else { candidate.pause() }
                } catch {
                    if applied.autoplay { try? active.play() }
                    throw error
                }
                self.monitor?.cancel()
                self.driver = candidate
                self.configuration.decoder = decoder
                self.snapshot = candidate.snapshot
                self.snapshot.time += self.timelineOffset
                self.snapshot.buffered += self.timelineOffset
                if self.originalDuration > 0 { self.snapshot.duration = self.originalDuration }
                self.onChange?()
                self.poll(generation: generation)
                await active.shutdown()
                return candidate.snapshot.actualDecoder
            } catch {
                await candidate.shutdown()
                throw error
            }
        }
        decoderPreparation = operation
        defer { if token == generation { decoderPreparation = nil } }
        return try await withTaskCancellationHandler { try await operation.value }
            onCancel: { operation.cancel() }
    }

    private func open(_ url: URL, preferred: EngineID, generation: UUID,
                      audio: EngineTrack?, subtitle: EngineTrack?, subtitlesOff: Bool) async {
        var order = [preferred] + EngineID.allCases.filter { $0 != preferred }
        order.removeAll { attempted.contains($0) }
        for id in order {
            guard token == generation, !Task.isCancelled else { return }
            if engineID != id, !attempted.isEmpty || hasTriedServer {
                onEngineFallback?(engineID, id)
            }
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
                if transcodingProvider != nil && localConfiguration.preloadCacheLimitBytes == nil {
                    localConfiguration.preloadCacheLimitBytes = await EmbyPreloadCacheSettings.currentLimitBytes()
                    guard token == generation, !Task.isCancelled else { await candidate.shutdown(); return }
                    self.configuration.preloadCacheLimitBytes = localConfiguration.preloadCacheLimitBytes
                }
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
                snapshot = state
                if hasTriedServer { transcodingProvider?.didActivateTranscoding() }
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
        // Each engine is tried once per bounded output tier: original, remux,
        // then a known H.264/AAC server encode. No unlimited failover loop.
        if serverAttemptCount < 2, let server = transcodingProvider {
            hasTriedServer = true
            serverAttemptCount += 1
            do {
                let transcode = try await server.transcode(position: configuration.position,
                                                          forceVideoTranscode: serverAttemptCount == 2)
                guard token == generation, !Task.isCancelled else { return }
                guard transcode.url.scheme?.lowercased() == "https" || transcode.url.isFileURL
                    || (transcode.url.scheme?.lowercased() == "http" && Self.isPrivateNetworkHost(transcode.url.host ?? "")) else {
                    throw PlaybackCoreError.failed("Emby 返回了不安全的远程 HTTP 转码地址。")
                }
                guard transcode.timelineOffset.isFinite, transcode.timelineOffset >= 0,
                      transcode.originalDuration.isFinite, transcode.originalDuration > transcode.timelineOffset else {
                    throw PlaybackCoreError.failed("服务器返回了无效的转码时间轴。")
                }
                timelineOffset = transcode.timelineOffset
                originalDuration = transcode.originalDuration
                self.url = transcode.url
                configuration.requestHeaders = transcode.headers
                configuration.mediaBitRate = transcode.bitRate
                attempted = []
                await open(transcode.url, preferred: .aether, generation: generation, audio: audio, subtitle: subtitle, subtitlesOff: subtitlesOff)
                return
            } catch {
                lastError = error
                var shouldRetry = !(error is CancellationError) && !(error is URLError)
                if let embyError = error as? EmbyError {
                    switch embyError {
                    case .authentication, .forbidden, .missingAccount: shouldRetry = false
                    default: break
                    }
                }
                if serverAttemptCount < 2 && shouldRetry {
                    await open(url, preferred: preferred, generation: generation,
                               audio: audio, subtitle: subtitle, subtitlesOff: subtitlesOff)
                    return
                }
            }
        }
        guard token == generation, !Task.isCancelled else { return }
        isTransitioning = false
        snapshot.phase = .failed(lastError?.localizedDescription ?? "所有播放引擎均无法播放此视频。")
        onChange?()
    }
    private func match(_ old: EngineTrack?, in tracks: [EngineTrack]) -> EngineTrack? {
        guard let old else { return nil }
        if old.id.hasPrefix("emby-preference:"),
           let ordinal = Int(old.id.dropFirst("emby-preference:".count)) {
            // Emby indices include video and other stream types. Use the ordinal
            // within this track type only when its metadata also agrees.
            if tracks.indices.contains(ordinal) {
                let candidate = tracks[ordinal]
                if (old.language == nil || candidate.language == old.language)
                    && (old.codec == nil || candidate.codec?.lowercased() == old.codec?.lowercased()) {
                    return candidate
                }
            }
        }
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
        var updated = value
        // The negotiated stream can change its headers during fallback.
        updated.requestHeaders = configuration.requestHeaders
        updated.preloadCacheLimitBytes = configuration.preloadCacheLimitBytes
        updated.mediaBitRate = configuration.mediaBitRate
        configuration = updated
        var local = updated; local.position = max(0, value.position - timelineOffset)
        driver?.configure(local)
    }
    func play() { configuration.autoplay = true; do { try driver?.play() } catch { log?(error.localizedDescription) } }
    func pause() { configuration.autoplay = false; driver?.pause() }
    func seek(to seconds: Double, resume: Bool, fast: Bool = false, completion: @escaping (Bool) -> Void) {
        guard let driver, !isTransitioning else { completion(false); return }
        if seconds < timelineOffset {
            guard let server = transcodingProvider else { completion(false); return }
            reopenServerStream(position: seconds, resume: resume, server: server, completion: completion)
            return
        }
        let generation = token
        let localSeconds = seconds - timelineOffset
        let pending = seekTask
        seekTask = Task { [weak self] in
            do {
                await pending?.value
                try Task.checkCancellation()
                try await driver.seek(to: localSeconds, fast: fast)
                try Task.checkCancellation()
                guard let self, self.token == generation else { completion(false); return }
                if resume { self.play() } else { self.pause() }
                completion(true)
            } catch {
                // A missing seek acknowledgement must not strand a previously
                // playing session in its scrub-preview pause. Never revive a
                // cancelled/replaced driver.
                if let self, self.token == generation, self.driver === driver, !Task.isCancelled {
                    if resume { self.play() } else { self.pause() }
                }
                completion(false)
            }
        }
    }
    private func reopenServerStream(position: Double, resume: Bool, server: any PlaybackTranscodingProvider,
                                    completion: @escaping (Bool) -> Void) {
        let generation = token
        let oldDriver = driver
        let oldSeek = seekTask
        let oldTransition = transition
        monitor?.cancel(); monitor = nil
        isTransitioning = true
        let audio = snapshot.audio.first { $0.selected }
        let subtitle = snapshot.subtitles.first { $0.selected }
        transition = Task { [weak self] in
            await oldTransition?.value
            await oldSeek?.value
            guard let self, self.token == generation, !Task.isCancelled else { completion(false); return }
            do {
                let stream = try await server.transcode(position: position, forceVideoTranscode: self.serverAttemptCount == 2)
                try Task.checkCancellation()
                guard self.token == generation else { completion(false); return }
                guard stream.url.scheme?.lowercased() == "https" || stream.url.isFileURL
                    || (stream.url.scheme?.lowercased() == "http" && Self.isPrivateNetworkHost(stream.url.host ?? "")) else {
                    throw PlaybackCoreError.failed("Emby 返回了不安全的远程 HTTP 转码地址。")
                }
                await oldDriver?.shutdown()
                self.driver = nil
                self.timelineOffset = stream.timelineOffset
                self.originalDuration = stream.originalDuration
                self.url = stream.url
                self.configuration.position = position
                self.configuration.autoplay = resume
                self.configuration.requestHeaders = stream.headers
                self.configuration.mediaBitRate = stream.bitRate
                self.attempted = []
                await self.open(stream.url, preferred: self.engineID, generation: generation,
                                audio: audio, subtitle: subtitle, subtitlesOff: subtitle == nil)
                completion(self.lastError == nil && self.driver != nil)
            } catch {
                guard self.token == generation else { completion(false); return }
                self.isTransitioning = false
                self.log?("服务器跳转失败：\(error.localizedDescription)")
                self.poll(generation: generation)
                completion(false)
            }
        }
    }
    func selectAudio(_ id: String) { driver?.selectAudio(id) }
    func selectSubtitle(_ id: String?) { driver?.selectSubtitle(id) }
    func startPiP() { driver?.startPiP() }
    func stopPiP() { driver?.stopPiP() }
    func setPiPActive(_ active: Bool) { driver?.setPiPActive(active) }

    private static func isPrivateNetworkHost(_ input: String) -> Bool {
        let host = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", "::1"].contains(host) || host.hasSuffix(".local") || host.hasSuffix(".lan")
            || host.hasSuffix(".home") || host.hasSuffix(".internal") { return true }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            return octets[0] == 10 || octets[0] == 127 || octets[0] == 192 && octets[1] == 168
                || octets[0] == 172 && (16...31).contains(octets[1])
                || octets[0] == 169 && octets[1] == 254
        }
        return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:")
    }
}

/// Sample the active network for each Emby load, including engine/server fallbacks.
enum EmbyPreloadCacheSettings {
    static let wifiKey = "emby.preload.wifiMB"
    static let cellularKey = "emby.preload.cellularMB"
    static let choices = [100, 250, 500, 1000, 2000]
    static let nextWiFiKey = "emby.preload.next.wifi"
    static let nextCellularKey = "emby.preload.next.cellular"
    static let nextPercentKey = "emby.preload.next.percent"
    static var nextPercent: Int {
        let value = UserDefaults.standard.object(forKey: nextPercentKey) as? Int ?? 90
        return min(99, max(1, value))
    }

    static func allowsNextEpisode() async -> Bool {
        let cellular = await usesCellularBudget()
        let key = cellular ? nextCellularKey : nextWiFiKey
        return UserDefaults.standard.object(forKey: key) as? Bool ?? !cellular
    }

    private static func usesCellularBudget() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                // Expensive or unknown connections use the cellular budget conservatively.
                continuation.resume(returning: path.isExpensive || !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet))
            }
            monitor.start(queue: DispatchQueue(label: "vesper.emby.preload-network"))
        }
    }

    static func currentLimitBytes() async -> Int {
        let cellular = await usesCellularBudget()
        let stored = UserDefaults.standard.object(forKey: cellular ? cellularKey : wifiKey) as? Int ?? 500
        return (choices.contains(stored) ? stored : 500) * 1_000_000
    }
}
