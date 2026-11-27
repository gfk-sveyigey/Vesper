import Foundation
import UIKit
import AVKit
import PlaybackContracts
internal import AetherEngine

/// AetherEngine and its complete decode dependency closure link ONLY here.
@MainActor public final class AetherDriver: PlaybackDriver {
    public let id: EngineID = .aether
    private var engine: AetherEngine?
    private var localPreview: FrameExtractor?
    private let surface = AetherPlayerView(frame: .zero)
    private var configuration = EngineConfiguration()
    private var lastUsableSnapshot: EngineSnapshot?
    private var manualPiPRequested = false
    private var measuresNetworkInput = false
    private var downloadSessionID = UUID().uuidString
    private var pip: AVPictureInPictureController?
    private weak var pipLayer: AVPlayerLayer?
    private weak var pipSampleLayer: AVSampleBufferDisplayLayer?
    public var restoreUI: ((@escaping (Bool) -> Void) -> Void)?
    public var view: UIView { surface }
    public init() {}

    /// Process-wide sink: do not capture a driver or reinstall for every load.
    public static func setLogHandler(_ handler: @escaping @Sendable (String) -> Void) {
        EngineLog.structuredHandler = { @Sendable line, category, _ in
            handler("[Aether][\(category.rawValue)] \(line)")
        }
    }
    public var nativePiPController: AVPictureInPictureController? {
        guard let engine else { return nil }
        // Do not attach a PiP content source for audio-only backgrounding.
        // Remove the system candidate entirely instead of relying on a
        // later lifecycle callback to dismiss an unwanted automatic window.
        guard configuration.automaticPiP || manualPiPRequested else {
            discardPiPController()
            return nil
        }
        if let layer = engine.nativePlayerLayer {
            if pipLayer !== layer {
                pip?.stopPictureInPicture()
                pipLayer = layer; pipSampleLayer = nil
                pip = AVPictureInPictureController(playerLayer: layer)
            }
        } else if let source = engine.softwarePiPSource {
            // The engine owns the sample-buffer playback delegate.
            if pipSampleLayer !== source.layer {
                pip?.stopPictureInPicture()
                pipLayer = nil; pipSampleLayer = source.layer
                pip = source.makePictureInPictureController()
            }
        }
        pip?.canStartPictureInPictureAutomaticallyFromInline = configuration.automaticPiP
        return pip
    }
    public var snapshot: EngineSnapshot {
        var result = EngineSnapshot()
        guard let engine else { return result }
        if engine.needsForegroundVideoRestore {
            // Background teardown parks selections inside Aether but clears
            // the public track lists. Preserve the last usable App snapshot
            // so a host-level Emby re-resolution can carry those choices.
            result = lastUsableSnapshot ?? result
            result.phase = .paused
            result.requiresForegroundReload = true
            result.pipPossible = pip?.isPictureInPicturePossible ?? false
            result.pipActive = pip?.isPictureInPictureActive ?? false
            return result
        }
        switch engine.state {
        case .idle: result.phase = .idle
        case .loading, .seeking: result.phase = .loading
        case .playing: result.phase = .playing
        case .paused: result.phase = .paused
        case .ended: result.phase = .ended
        case .error(let message): result.phase = .failed(message)
        }
        result.time = engine.clock.currentTime
        result.duration = engine.duration
        result.buffered = engine.bufferedPosition
        result.bufferedRanges = engine.residentRanges
        result.seekable = result.duration > 0
        if let decoder = engine.activeVideoDecoder {
            if decoder.contains("(SW)") { result.actualDecoder = .software }
            else if decoder.contains("(HW)") { result.actualDecoder = .hardware }
        }
        if engine.playbackBackend == .native { result.actualDecoder = .hardware }
        result.audio = engine.audioTracks.map {
            .init(id: String($0.id), name: $0.name, language: $0.language, codec: $0.codec,
                  selected: $0.id == engine.activeAudioTrackIndex, channels: $0.channels > 0 ? $0.channels : nil)
        }
        result.subtitles = engine.subtitleTracks.map { .init(id: String($0.id), name: $0.name, language: $0.language, codec: $0.codec, selected: $0.id == engine.activeSubtitleTrackIndex) }
        if let pip = nativePiPController {
            result.pipPossible = pip.isPictureInPicturePossible
            result.pipActive = pip.isPictureInPictureActive
        } else {
            // Keep the manual button available without creating an automatic
            // system candidate. Actual readiness is checked after preparePiP.
            result.pipPossible = AVPictureInPictureController.isPictureInPictureSupported()
                && (engine.nativePlayerLayer?.isReadyForDisplay == true || engine.softwarePiPSource != nil)
        }
        if result.duration > 0 { lastUsableSnapshot = result }
        return result
    }
    public var mediaInformation: MediaProbe? {
        guard let engine else { return nil }
        var result = MediaProbe()
        result.duration = engine.duration
        result.width = Int(engine.sourceVideoWidth)
        result.height = Int(engine.sourceVideoHeight)
        result.hasVideo = result.width > 0 && result.height > 0
        result.container = engine.sourceContainerFormat
        result.fields["视频编码"] = engine.sourceVideoCodecName
        if result.hasVideo { result.fields["动态范围"] = String(describing: engine.sourceVideoFormat) }
        if let rate = engine.sourceVideoFrameRate, rate.isFinite, rate > 0 {
            result.fields["帧率"] = String(format: "%.3f fps", rate)
        }
        if engine.sourceVideoBitrate > 0 {
            result.fields["视频码率"] = String(format: "%.1f kbit/s", Double(engine.sourceVideoBitrate) / 1000)
        }
        if let format = engine.sourceVideoStreamFormat {
            result.fields["像素格式"] = format.pixelFormat
            result.fields["视频位深"] = format.bitDepth.map { "\($0) bit" }
            result.fields["色彩原色"] = format.colorPrimaries
            result.fields["传递函数"] = format.transfer
            result.fields["色彩矩阵"] = format.matrix
            result.fields["全范围色彩"] = format.range
            result.fields["编码规格"] = format.profile
        }
        result.fields["音轨数量"] = String(engine.audioTracks.count)
        if let audio = engine.audioTracks.first(where: { $0.id == engine.activeAudioTrackIndex }) ?? engine.audioTracks.first {
            result.fields["音频编码"] = audio.codec
            result.fields["音频语言"] = audio.language
            if audio.sampleRate > 0 { result.fields["采样率"] = "\(audio.sampleRate) Hz" }
            if audio.channels > 0 { result.fields["声道数"] = String(audio.channels) }
            if audio.bitrate > 0 { result.fields["音频码率"] = String(format: "%.1f kbit/s", Double(audio.bitrate) / 1000) }
            if audio.bitsPerSample > 0 { result.fields["音频位深"] = String(audio.bitsPerSample) }
            result.fields["声道布局"] = audio.channelLayout
        }
        return result
    }

    public var downloadSample: EngineDownloadSample? {
        guard measuresNetworkInput, let engine, !engine.needsForegroundVideoRestore else { return nil }
        let bytes: Int64
        switch engine.videoRoute {
        case .remoteBypass:
            guard let telemetry = engine.liveTelemetry else { return nil }
            guard let transferred = telemetry.networkTransferredBytes else { return nil }
            bytes = transferred
        case .loopback, .software:
            guard let telemetry = engine.liveTelemetry else { return nil }
            bytes = telemetry.demuxerBytesFetched
        default: return nil
        }
        let route = engine.videoRoute.rawValue
        return .init(counterID: "\(downloadSessionID):\(route)", bytes: bytes)
    }

    public var diagnosticMetrics: [EngineDiagnosticMetric] {
        guard let engine else { return [] }
        var metrics = [EngineDiagnosticMetric("播放后端", engine.playbackBackend.rawValue)]
        if let decoder = engine.activeVideoDecoder {
            metrics.append(.init("解码器", decoder))
        }
        guard let telemetry = engine.liveTelemetry else { return metrics }
        func add(_ title: String, _ value: Double?, suffix: String, digits: Int = 1) {
            guard let value, value.isFinite else { return }
            metrics.append(.init(title, String(format: "%.*f%@", digits, value, suffix)))
        }
        add("当前码率", telemetry.instantBitrateMbps, suffix: " Mb/s")
        add("平均码率", telemetry.averageBitrateMbps, suffix: " Mb/s")
        add("网络吞吐", telemetry.networkThroughputMbps, suffix: " Mb/s")
        add("视频帧率", telemetry.observedFps, suffix: " fps")
        if let dropped = telemetry.droppedFrameCount { metrics.append(.init("丢帧数", "\(dropped)")) }
        add("前向缓冲", telemetry.forwardBufferSeconds, suffix: " s")
        add("显示队列", telemetry.displayCushionSeconds, suffix: " s")
        if let bytes = telemetry.readerWindowAheadBytes { metrics.append(.init("读取缓存", Self.byteCount(bytes))) }
        if let bytes = telemetry.cachedBytes { metrics.append(.init("数据缓存", Self.byteCount(bytes))) }
        add("音画偏差", telemetry.avSyncGapMs, suffix: " ms")
        metrics.append(.init("内存占用", "\(telemetry.rssMb) MB"))
        return metrics
    }

    private static func byteCount<T: BinaryInteger>(_ count: T) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
    public func load(url: URL, configuration: EngineConfiguration) async throws {
        localPreview = url.isFileURL ? FrameExtractor(url: url) : nil
        measuresNetworkInput = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        downloadSessionID = UUID().uuidString
        let engine = try AetherEngine()
        self.engine = engine
        engine.deactivatesAudioSessionOnStop = false
        // Preserve paused sessions across background suspension instead of
        // tearing down after the default grace window. System-invalidated
        // pipelines still use the existing foreground/error recovery paths.
        engine.retainsVideoPipelineWhenBackgrounded = true
        engine.bind(view: surface)
        self.configuration = configuration
        lastUsableSnapshot = nil
        configure(configuration)
        var options = LoadOptions()
        options.autoplay = configuration.autoplay
        options.preferredDecodePath = configuration.decoder == .software ? .software : .automatic
        options.httpHeaders = configuration.requestHeaders
        // Prepare engine-owned subtitle rendering for inline and PiP playback.
        options.prepareNativeSubtitles = true
        if let limit = configuration.preloadCacheLimitBytes {
            options.sessionCacheByteBudget = limit
            options.sessionCacheHardLimitBytes = limit
        }
        options.externalSubtitles = configuration.externalSubtitles.map {
            ExternalSubtitleTrack(url: $0.url, name: $0.name, language: $0.language,
                                  httpHeaders: $0.headers, formatHint: $0.format)
        }
        _ = try await engine.load(url: url, startPosition: configuration.position, options: options)
        try Task.checkCancellation()
        engine.clearSubtitle()
        configure(configuration)
    }
    public func configure(_ configuration: EngineConfiguration) {
        let disablingAutomaticPiP = self.configuration.automaticPiP && !configuration.automaticPiP
        self.configuration = configuration
        if disablingAutomaticPiP {
            manualPiPRequested = false
            discardPiPController()
        }
        engine?.setNativeSubtitleRendering(true)
        engine?.backgroundPlaybackEnabled = configuration.backgroundEnabled
        engine?.volume = configuration.muted ? 0 : 1
        engine?.setRate(configuration.rate)
        engine?.currentAVPlayer?.allowsExternalPlayback = true
        if let item = engine?.currentAVPlayer?.currentItem,
           let rule = AVTextStyleRule(textMarkupAttributes: [
               kCMTextMarkupAttribute_RelativeFontSize as String: configuration.subtitleFontSize / 22 * 100
           ]) {
            item.textStyleRules = [rule]
        }
        engine?.videoGravity = configuration.fillsScreen && pip?.isPictureInPictureActive != true ? .resizeAspectFill : .resizeAspect
        pip?.canStartPictureInPictureAutomaticallyFromInline = configuration.automaticPiP
    }
    public func play() throws { engine?.play() }
    public func pause() { engine?.pause() }
    public var renderedFrameMarker: Double? {
        guard let engine, engine.sourceTimeFollowsPicture, engine.sourceTime.isFinite else { return nil }
        return engine.sourceTime
    }
    public func seek(to seconds: Double) async throws { try await seek(to: seconds, fast: false) }
    public func seek(to seconds: Double, fast: Bool) async throws {
        guard let engine else { throw PlaybackCoreError.cancelled }
        await engine.seek(to: seconds, exact: !fast)
        try Task.checkCancellation()
    }
    public func scrubPreview(at seconds: Double) async -> UIImage? {
        if let localPreview {
            let image = await localPreview.thumbnail(at: seconds)
            return image.map { UIImage(cgImage: $0) }
        }
        let frame = await engine?.scrubPreviewFrame(atSeconds: seconds, refined: false, isCancelled: { Task.isCancelled })
        return frame.map { UIImage(cgImage: $0.image) }
    }
    public func shutdown() async {
        pip?.delegate = nil; pip?.stopPictureInPicture(); pip = nil; pipLayer = nil; pipSampleLayer = nil
        engine?.stop(finalTeardown: true)
        await engine?.releaseScrubPreviewDecoders()
        await localPreview?.shutdown()
        localPreview = nil
        engine = nil
        manualPiPRequested = false
    }
    public func selectAudio(_ id: String) { if let index = Int(id) { engine?.selectAudioTrack(index: index) } }
    public func selectSubtitle(_ id: String?) { if let id, let index = Int(id) { engine?.selectSubtitleTrack(index: index) } else { engine?.clearSubtitle() } }
    public func setPiPActive(_ active: Bool) {
        if !active { manualPiPRequested = false }
        engine?.pictureInPictureActive = active
        // Keep subtitles engine-rendered when returning from PiP too.
        engine?.setNativeSubtitleRendering(true)
        engine?.videoGravity = active || !configuration.fillsScreen ? .resizeAspect : .resizeAspectFill
    }
    public func preparePiP() { manualPiPRequested = true }
    public func startPiP() {
        engine?.videoGravity = .resizeAspect
        nativePiPController?.startPictureInPicture()
    }
    public func stopPiP() { pip?.stopPictureInPicture() }

    private func discardPiPController() {
        guard pip != nil else { return }
        pip?.delegate = nil
        pip?.stopPictureInPicture()
        pip?.contentSource = nil
        pip = nil; pipLayer = nil; pipSampleLayer = nil
        engine?.pictureInPictureActive = false
    }

}

/// Probing does not create a playback engine or touch the audio session.
public enum AetherMediaProbe {
    public static func inspect(_ url: URL) throws -> MediaProbe {
        let probe = try AetherEngine.probe(url: url)
        var result = MediaProbe()
        result.duration = probe.durationSeconds
        result.width = Int(probe.videoWidth); result.height = Int(probe.videoHeight)
        result.hasVideo = probe.videoCodecID != 0 && result.width > 0 && result.height > 0
        result.container = probe.containerFormat
        result.fields["视频编码"] = probe.videoCodecName
        result.fields["动态范围"] = String(describing: probe.videoFormat)
        result.fields["视频轨道数量"] = result.hasVideo ? "1" : "0"
        result.fields["音轨数量"] = String(probe.audioTracks.count)
        if let rate = probe.videoFrameRate { result.fields["帧率"] = String(format: "%.3f fps", rate) }
        if let format = probe.videoStreamFormat {
            result.fields["像素格式"] = format.pixelFormat
            result.fields["视频位深"] = format.bitDepth.map { "\($0) bit" }
            result.fields["色彩原色"] = format.colorPrimaries
            result.fields["传递函数"] = format.transfer
            result.fields["色彩矩阵"] = format.matrix
            result.fields["全范围色彩"] = format.range
            result.fields["编码规格"] = format.profile
        }
        if let audio = probe.audioTracks.first {
            result.fields["音频编码"] = audio.codec
            if audio.sampleRate > 0 { result.fields["采样率"] = "\(audio.sampleRate) Hz" }
            if audio.channels > 0 { result.fields["声道数"] = String(audio.channels) }
            if audio.bitrate > 0 { result.fields["音频码率"] = String(format: "%.1f kbit/s", Double(audio.bitrate) / 1000) }
        }
        return result
    }
}

/// Keep upstream types behind the playback bridge.
public enum AetherSourcePrewarm {
    public static func prepare(url: URL, headers: [String: String], byteBudget: Int) async -> Bool {
        let report = await AetherEngine.prewarm(url: url, httpHeaders: headers, byteBudget: byteBudget)
        return report.isWarm
    }

    public static func discard() { AetherEngine.discardPrewarmedSources() }
}
