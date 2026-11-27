import Foundation
import Network
import UIKit
import AVKit
import PlaybackContracts
import VesperAetherBridge
import VesperVLCBridge

enum PlaybackDiagnostics {
    static let detachHiddenVideoSurfaceKey = "debug.playback.detachHiddenVideoSurface"
    static let throttleHiddenPausedPollingKey = "debug.playback.throttleHiddenPausedPolling"
    static let controlEdgeSpacingKey = "debug.playback.controlEdgeSpacing"
    static let defaultControlEdgeSpacing = 10
    static let controlEdgeSpacingRange = 0...60
    static let controlGradientStrengthKey = "debug.playback.controlGradientStrength"
    static let defaultControlGradientStrength = 100
    static let controlGradientStrengthRange = 0...100
    static let controlGlassClearKey = "debug.playback.controlGlassClear"
}

/// Server fallback is supplied only for an authenticated server-backed item.
/// Local/Photos sources must never be silently uploaded to a server.
struct TranscodedPlaybackResource: Sendable {
    let url: URL
    var headers: [String: String] = [:]
    /// Original-media time represented by time zero of the returned stream.
    let timelineOffset: Double
    let originalDuration: Double
}

@MainActor protocol PlaybackTranscodingProvider: AnyObject {
    func transcode(position: Double, forceVideoTranscode: Bool) async throws -> TranscodedPlaybackResource
    func stopTranscoding() async
    func didActivateTranscoding()
}

enum PlaybackTrackIntent {
    case automatic
    case off
    case track(EngineTrack)

    var initialRestoreStatus: PlaybackTrackRestoreStatus {
        if case .track = self { return .restoring }
        return .none
    }

    var isOff: Bool {
        if case .off = self { return true }
        return false
    }

    func carryingSelection(from tracks: [EngineTrack]) -> Self {
        guard case .automatic = self, let selected = tracks.first(where: { $0.selected }) else { return self }
        return .track(selected)
    }
}

enum PlaybackTrackRestoreStatus: Equatable {
    case none, restoring, unavailable
}

struct PlaybackTrackRestoration {
    enum Command: Equatable { case off, select(String) }
    private var deadline: TimeInterval?
    private var localID: String?
    private var lastMatchedTracks: [EngineTrack]?
    private var lastMatch: EngineTrack?
    private var lastCommand: Command?
    private var lastAttempt: TimeInterval?
    private(set) var status: PlaybackTrackRestoreStatus = .none
    private(set) var targetID: String?

    mutating func begin(_ intent: PlaybackTrackIntent, now: TimeInterval, localID: String? = nil) {
        self = Self()
        self.localID = localID
        if case .track = intent {
            deadline = now + 5
            status = .restoring
            targetID = localID
        }
    }

    mutating func update(_ intent: PlaybackTrackIntent, tracks: [EngineTrack], now: TimeInterval,
                         suppressUnmatchedTrack: Bool = false,
                         match: (EngineTrack, [EngineTrack]) -> EngineTrack?) -> Command? {
        let command: Command
        switch intent {
        case .automatic: return nil
        case .off:
            // Send once on open, and again if a late/default track gets selected.
            guard lastCommand == nil || tracks.contains(where: { $0.selected }) else { return nil }
            command = .off
        case .track(let requested):
            guard let deadline else { return nil }
            if lastMatchedTracks != tracks {
                lastMatchedTracks = tracks
                if let localID { lastMatch = tracks.first { $0.id == localID } }
                else { lastMatch = match(requested, tracks) }
            }
            let target = lastMatch
            targetID = target?.id
            if target?.selected == true {
                self.deadline = nil
                status = .none
                return nil
            }
            status = now < deadline ? .restoring : .unavailable
            if let target {
                command = .select(target.id)
            } else {
                // Keep watching: a paused or slow input may enumerate tracks late.
                if case .select(_)? = lastCommand {
                    lastCommand = nil
                    lastAttempt = nil
                }
                guard suppressUnmatchedTrack, tracks.contains(where: { $0.selected }) else { return nil }
                command = .off
            }
        }
        if command == lastCommand, let lastAttempt, now - lastAttempt < 1 { return nil }
        // Don't repeatedly send an unacknowledged command after the grace period.
        if status == .unavailable, case .select = command, command == lastCommand { return nil }
        lastCommand = command
        lastAttempt = now
        return command
    }
}

/// The UI talks only to this owner. Engine creation, retirement and failover
/// share one serial task chain. Decoder switching stages a muted candidate.
@MainActor final class PlaybackCore {
    private(set) var driver: (any PlaybackDriver)?
    private(set) var engineID: EngineID = .aether
    private(set) var snapshot = EngineSnapshot()
    private(set) var isTransitioning = false
    var isPlayerPresented = false
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
    var playbackURL: URL? { url }
    var requestedAutoplay: Bool { configuration.autoplay }
    private var configuration = EngineConfiguration()
    private var attempted: Set<EngineID> = []
    private var hasTriedServer = false
    private var serverAttemptCount = 0
    private var lastError: Error?
    private var audioIntent: PlaybackTrackIntent = .automatic
    private var subtitleIntent: PlaybackTrackIntent = .automatic
    private var audioRestoration = PlaybackTrackRestoration()
    private var subtitleRestoration = PlaybackTrackRestoration()
    var audioRestoreStatus: PlaybackTrackRestoreStatus { audioRestoration.status }
    var subtitleRestoreStatus: PlaybackTrackRestoreStatus { subtitleRestoration.status }
    var restoringAudioID: String? { audioRestoreStatus == .restoring ? audioRestoration.targetID : nil }
    var restoringSubtitleID: String? { subtitleRestoreStatus == .restoring ? subtitleRestoration.targetID : nil }
    var subtitlesExplicitlyOff: Bool { subtitleIntent.isOff }

    func carriedTrackIntents() -> (audio: PlaybackTrackIntent, subtitle: PlaybackTrackIntent) {
        let state = snapshot.requiresForegroundReload ? snapshot : driver?.snapshot ?? snapshot
        return (audioIntent.carryingSelection(from: state.audio), subtitleIntent.carryingSelection(from: state.subtitles))
    }

    private func retainTrackIntents(from state: EngineSnapshot) {
        audioIntent = audioIntent.carryingSelection(from: state.audio)
        subtitleIntent = subtitleIntent.carryingSelection(from: state.subtitles)
    }

    private func beginTrackRestoration() {
        let now = ProcessInfo.processInfo.systemUptime
        audioRestoration.begin(audioIntent, now: now)
        subtitleRestoration.begin(subtitleIntent, now: now)
    }

    private func restoreTracks(on driver: any PlaybackDriver, from state: EngineSnapshot) {
        let now = ProcessInfo.processInfo.systemUptime
        if case .select(let id)? = audioRestoration.update(audioIntent, tracks: state.audio, now: now, match: Self.match(_:in:)) {
            driver.selectAudio(id)
        }
        switch subtitleRestoration.update(subtitleIntent, tracks: state.subtitles, now: now,
                                          suppressUnmatchedTrack: true, match: Self.match(_:in:)) {
        case .off?: driver.selectSubtitle(nil)
        case .select(let id)?: driver.selectSubtitle(id)
        case nil: break
        }
    }
    private var isAppBackgrounded = false
    private var aetherBackgroundRecoveryPending = false
    private var timelineOffset: Double = 0
    private var originalDuration: Double = 0
    var view: UIView? { driver?.view }
    var nativePiPController: AVPictureInPictureController? { driver?.nativePiPController }

    func load(_ url: URL, preferred: EngineID, configuration: EngineConfiguration, audio: PlaybackTrackIntent,
              subtitle: PlaybackTrackIntent, server: (any PlaybackTranscodingProvider)? = nil) async throws {
        let barrier = shutdown()
        audioIntent = audio
        subtitleIntent = subtitle
        beginTrackRestoration()
        aetherBackgroundRecoveryPending = false
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
            await self.open(url, preferred: preferred, generation: generation)
        }
        transition = operation
        await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        if let lastError { throw lastError }
    }

    func setAppBackgrounded(_ backgrounded: Bool) {
        isAppBackgrounded = backgrounded
        if backgrounded, engineID == .aether { aetherBackgroundRecoveryPending = true }
    }
    /// Return a retirement barrier so file access is kept alive until all native
    /// readers and pending open/seek work stop. Never await yourself in this chain.
    @discardableResult func shutdown() -> Task<Void, Never> {
        audioIntent = .automatic; subtitleIntent = .automatic
        audioRestoration = PlaybackTrackRestoration(); subtitleRestoration = PlaybackTrackRestoration()
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
                self.retainTrackIntents(from: active.snapshot)
                self.driver = candidate
                self.beginTrackRestoration()
                self.restoreTracks(on: candidate, from: candidate.snapshot)
                self.configuration.decoder = decoder
                self.snapshot = candidate.snapshot
                self.snapshot.time += self.timelineOffset
                self.snapshot.buffered += self.timelineOffset
                self.snapshot.bufferedRanges = self.snapshot.bufferedRanges.map { range in
                    (range.lowerBound + self.timelineOffset)...(range.upperBound + self.timelineOffset)
                }
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

    private func open(_ url: URL, preferred: EngineID, generation: UUID) async {
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
                beginTrackRestoration()
                restoreTracks(on: candidate, from: candidate.snapshot)
                snapshot = candidate.snapshot
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
                attempted = []
                await open(transcode.url, preferred: .aether, generation: generation)
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
                    await open(url, preferred: preferred, generation: generation)
                    return
                }
            }
        }
        guard token == generation, !Task.isCancelled else { return }
        isTransitioning = false
        snapshot.phase = .failed(lastError?.localizedDescription ?? "所有播放引擎均无法播放此视频。")
        onChange?()
    }
    private static func match(_ old: EngineTrack, in tracks: [EngineTrack]) -> EngineTrack? {
        // Neither bridge currently exposes a common source-stream identifier.
        // Its native ID is safe only within the live driver that supplied it.
        let language = EmbyTrackPreferences.normalized(old.language ?? "")
        let script = chineseScript(old)
        let title = comparableTitle(old.sourceTitle ?? old.name)
        let codec = trackCodec(old.codec)
        let compatible = tracks.filter { track in
            let candidateLanguage = EmbyTrackPreferences.normalized(track.language ?? "")
            guard language.isEmpty || candidateLanguage.isEmpty || language == candidateLanguage else { return false }
            if let channels = old.channels, channels > 0,
               let candidateChannels = track.channels, candidateChannels > 0, candidateChannels != channels { return false }
            guard let script, let candidateScript = chineseScript(track) else { return true }
            return script == candidateScript
        }
        func unique(_ candidates: [EngineTrack]) -> EngineTrack? {
            candidates.count == 1 ? candidates[0] : nil
        }
        let sameLanguage = compatible.filter {
            !language.isEmpty && EmbyTrackPreferences.normalized($0.language ?? "") == language
        }
        let exactTitle = compatible.filter {
            !title.isEmpty && comparableTitle($0.sourceTitle ?? $0.name) == title && (script == nil || chineseScript($0) == script)
        }

        // The detail page's Emby hint uses server stream order, not an engine ID.
        if old.id.hasPrefix("emby-preference:") {
            if let script, let candidate = unique(sameLanguage.filter({ chineseScript($0) == script })) {
                return candidate
            }
            if let candidate = unique(exactTitle) { return candidate }
            if let ordinal = Int(old.id.dropFirst("emby-preference:".count)), tracks.indices.contains(ordinal) {
                let candidate = tracks[ordinal]
                if (sameLanguage.isEmpty ? compatible : sameLanguage).contains(where: { $0.id == candidate.id }),
                   script == nil || chineseScript(candidate) == script {
                    return candidate
                }
            }
        }

        if let candidate = unique(exactTitle.filter({ !codec.isEmpty && trackCodec($0.codec) == codec })) {
            return candidate
        }
        if let candidate = unique(exactTitle) { return candidate }
        if !exactTitle.isEmpty { return nil }
        // Don't degrade from a known script to an unspecified or different script.
        let sameLanguageAndScript = sameLanguage.filter { script == nil || chineseScript($0) == script }
        let sameCodec = sameLanguageAndScript.filter { !codec.isEmpty && trackCodec($0.codec) == codec }
        if let candidate = unique(sameCodec) { return candidate }
        if let channels = old.channels, channels > 0 {
            let candidates = sameCodec.isEmpty ? sameLanguageAndScript : sameCodec
            if let candidate = unique(candidates.filter({ $0.channels == channels })) { return candidate }
        }
        return unique(sameLanguageAndScript)
    }

    private static func trackLabel(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func comparableTitle(_ value: String) -> String {
        let label = trackLabel(value)
        if label.range(of: #"^(?:(?:track|audio(?: track)?|subtitle(?: track)?|音轨|字幕|軌道|声道)\s*#?\s*)?\d+(?: \([^)]+\))?$"#,
                       options: .regularExpression) != nil { return "" }
        return label
    }

    private static func trackCodec(_ value: String?) -> String {
        switch trackLabel(value ?? "") {
        case "srt", "subrip", "subt": return "subrip"
        case "ssa", "ass": return "ass"
        case "aac", "mp4a": return "aac"
        case "ac-3", "a52": return "ac3"
        case "e-ac-3", "eac3": return "eac3"
        default: return trackLabel(value ?? "")
        }
    }

    private static func chineseScript(_ track: EngineTrack) -> String? {
        let language = (track.language ?? "").lowercased().replacingOccurrences(of: "_", with: "-")
        let text = trackLabel(track.name + " " + (track.sourceTitle ?? ""))
        if language.contains("hans") || ["-cn", "-sg"].contains(where: { language.hasSuffix($0) })
            || ["简体", "簡體", "simplified", "hans"].contains(where: { text.contains($0) }) { return "hans" }
        if language.contains("hant") || ["-tw", "-hk", "-mo"].contains(where: { language.hasSuffix($0) })
            || ["繁体", "繁體", "traditional", "hant"].contains(where: { text.contains($0) }) { return "hant" }
        return nil
    }
    private func poll(generation: UUID) {
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.token == generation, let driver = self.driver else { return }
                let previous = self.snapshot
                let previousAudioStatus = self.audioRestoreStatus
                let previousSubtitleStatus = self.subtitleRestoreStatus
                let previousAudioTarget = self.restoringAudioID
                let previousSubtitleTarget = self.restoringSubtitleID
                self.snapshot = driver.snapshot
                if self.timelineOffset > 0 || self.originalDuration > 0 {
                    self.snapshot.time += self.timelineOffset
                    self.snapshot.buffered += self.timelineOffset
                    self.snapshot.bufferedRanges = self.snapshot.bufferedRanges.map { range in
                        (range.lowerBound + self.timelineOffset)...(range.upperBound + self.timelineOffset)
                    }
                    self.snapshot.duration = self.originalDuration
                }
                if self.engineID == .aether, self.aetherBackgroundRecoveryPending,
                   !self.isAppBackgrounded, self.snapshot.phase == .playing {
                    self.aetherBackgroundRecoveryPending = false
                }
                if case .failed(let message) = self.snapshot.phase {
                    if self.engineID == .aether, self.aetherBackgroundRecoveryPending {
                        self.snapshot = previous
                        self.snapshot.phase = .paused
                        self.snapshot.requiresForegroundReload = true
                        self.onChange?()
                        self.log?("Aether 后台会话失效，等待前台重载：\(message)")
                        return
                    }
                    self.configuration.position = previous.time
                    if previous.phase == .playing { self.configuration.autoplay = true }
                    else if previous.phase == .paused { self.configuration.autoplay = false }
                    self.retainTrackIntents(from: previous)
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
                        await self.open(url, preferred: .aether, generation: generation)
                    }
                    self.transition = operation
                    return
                }
                self.restoreTracks(on: driver, from: self.snapshot)
                if Self.needsStateNotification(from: previous, to: self.snapshot)
                    || previousAudioStatus != self.audioRestoreStatus || previousSubtitleStatus != self.subtitleRestoreStatus
                    || previousAudioTarget != self.restoringAudioID || previousSubtitleTarget != self.restoringSubtitleID {
                    self.onChange?()
                }
                let shouldThrottleHiddenPause = UserDefaults.standard.bool(
                    forKey: PlaybackDiagnostics.throttleHiddenPausedPollingKey
                ) && !self.isPlayerPresented && self.snapshot.phase == .paused
                do {
                    if shouldThrottleHiddenPause { try await Task.sleep(for: .seconds(1)) }
                    else { try await Task.sleep(for: .milliseconds(150)) }
                } catch { return }
            }
        }
    }


    private static func needsStateNotification(from old: EngineSnapshot, to new: EngineSnapshot) -> Bool {
        old.phase != new.phase
            || abs(old.time - new.time) > 0.01
            || abs(old.duration - new.duration) > 0.01
            || abs(old.buffered - new.buffered) > 0.01
            || old.bufferedRanges != new.bufferedRanges
            || old.seekable != new.seekable
            || old.actualDecoder != new.actualDecoder
            || old.audio != new.audio
            || old.subtitles != new.subtitles
            || old.subtitleText != new.subtitleText
            || old.subtitleImage !== new.subtitleImage
            || old.pipPossible != new.pipPossible
            || old.pipActive != new.pipActive
            || old.requiresForegroundReload != new.requiresForegroundReload
    }

    func waitUntilRetired() async { await transition?.value }
    func configure(_ value: EngineConfiguration) {
        var updated = value
        // The negotiated stream can change its headers during fallback.
        updated.requestHeaders = configuration.requestHeaders
        updated.preloadCacheLimitBytes = configuration.preloadCacheLimitBytes
        configuration = updated
        var local = updated; local.position = max(0, value.position - timelineOffset)
        driver?.configure(local)
    }
    func play() { configuration.autoplay = true; do { try driver?.play() } catch { log?(error.localizedDescription) } }
    func pause() { configuration.autoplay = false; driver?.pause() }
    func scrubPreview(at seconds: Double) async -> UIImage? {
        guard let driver, !isTransitioning, seconds >= timelineOffset else { return nil }
        let image = await driver.scrubPreview(at: seconds - timelineOffset)
        return self.driver === driver && !isTransitioning ? image : nil
    }
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
        retainTrackIntents(from: snapshot)
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
                self.attempted = []
                await self.open(stream.url, preferred: self.engineID, generation: generation)
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
    func selectAudio(_ id: String) {
        guard !isTransitioning, let driver else { return }
        let state = driver.snapshot
        guard let track = state.audio.first(where: { $0.id == id }) else { return }
        audioIntent = .track(track)
        audioRestoration.begin(audioIntent, now: ProcessInfo.processInfo.systemUptime, localID: id)
        restoreTracks(on: driver, from: state)
    }
    func selectSubtitle(_ id: String?) {
        guard !isTransitioning, let driver else { return }
        let state = driver.snapshot
        if let id {
            guard let track = state.subtitles.first(where: { $0.id == id }) else { return }
            subtitleIntent = .track(track)
        } else {
            subtitleIntent = .off
        }
        subtitleRestoration.begin(subtitleIntent, now: ProcessInfo.processInfo.systemUptime, localID: id)
        restoreTracks(on: driver, from: state)
    }
    func preparePiP() { driver?.preparePiP() }
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
