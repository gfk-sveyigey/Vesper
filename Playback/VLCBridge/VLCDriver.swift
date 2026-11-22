import Foundation
import UIKit
import SwiftUI
import AVKit
import PlaybackContracts
internal import SwiftVLC

@MainActor public final class VLCDriver: PlaybackDriver {
    public let id: EngineID = .vlc
    private var player: Player?
    private var hosting: UIHostingController<AnyView>?
    private let surface = UIView()
    private var pip: PiPController?
    private var configuration = EngineConfiguration()
    private var hasInstalledSurface = false
    private var timelineEvents: Task<Void, Never>?
    private var pendingSeekTime: Double?
    private var seekClockDeadline = Date.distantPast
    private var measuresNetworkInput = false
    private var downloadSessionID = UUID().uuidString
    private var previousDiagnosticSample: (date: Date, pictures: UInt64)?
    public var restoreUI: ((@escaping (Bool) -> Void) -> Void)?
    public var view: UIView { surface }
    // SwiftVLC owns the native AVKit delegate. Do not replace it from the App.
    public var nativePiPController: AVPictureInPictureController? { nil }
    private static var engineLogHandler: (@Sendable (String) -> Void)?
    private static var engineLogTask: Task<Void, Never>?

    public static func setLogHandler(_ handler: @escaping @Sendable (String) -> Void) {
        engineLogHandler = handler
    }

    private static func startLoggingIfNeeded() {
        guard engineLogTask == nil, let handler = engineLogHandler else { return }
        // Subscribe before Player() opens any media. One consumer per shared VLC
        // instance survives driver retirement and decoder/engine switches.
        let stream = VLCInstance.shared.logStream(minimumLevel: .notice)
        engineLogTask = Task.detached(priority: .utility) {
            for await entry in stream {
                guard !Task.isCancelled else { return }
                handler("[SwiftVLC][\(entry.level)][\(entry.module ?? "vlc")] \(entry.message)")
            }
        }
    }

    public init() {
        Self.startLoggingIfNeeded()
        surface.backgroundColor = .black
    }
    public var snapshot: EngineSnapshot {
        var result = EngineSnapshot()
        guard let player else { return result }
        // Never leave the UI pinned indefinitely if native acknowledgement is
        // absent (paused inputs may legitimately publish none).
        if Date() >= seekClockDeadline { pendingSeekTime = nil }
        switch player.state {
        case .idle, .stopped, .stopping: result.phase = player.didReachEnd ? .ended : .idle
        case .opening, .buffering: result.phase = .loading
        case .playing: result.phase = player.isPlaying ? .playing : .paused
        case .paused: result.phase = .paused
        case .error: result.phase = .failed("SwiftVLC: 播放失败")
        }
        result.time = pendingSeekTime ?? seconds(player.currentTime)
        result.duration = player.duration.map(seconds) ?? 0
        // bufferFill is a cache percentage, NOT a position in the file.
        result.buffered = result.time
        result.seekable = player.isSeekable
        result.actualDecoder = configuration.decoder == .software ? .software : nil
        result.audio = player.audioTracks.map { .init(id: $0.id, name: $0.name, language: $0.language, codec: $0.codecString, selected: $0.isSelected) }
        result.subtitles = player.subtitleTracks.map { .init(id: $0.id, name: $0.name, language: $0.language, codec: $0.codecString, selected: $0.isSelected) }
        result.pipPossible = pip?.isPossible ?? false
        result.pipActive = pip?.isActive ?? false
        return result
    }
    public var mediaInformation: MediaProbe? {
        guard let player else { return nil }
        var result = MediaProbe()
        result.duration = player.duration.map(seconds) ?? 0
        result.fields["视频轨道数量"] = String(player.videoTracks.count)
        result.fields["音轨数量"] = String(player.audioTracks.count)
        if let video = player.videoTracks.first(where: { $0.isSelected }) ?? player.videoTracks.first {
            result.width = video.width ?? 0
            result.height = video.height ?? 0
            result.hasVideo = true
            result.fields["视频编码"] = video.codecString
            if let fps = video.frameRate, fps.isFinite, fps > 0 { result.fields["帧率"] = String(format: "%.3f fps", fps) }
            if video.bitrate > 0 { result.fields["视频码率"] = String(format: "%.1f kbit/s", Double(video.bitrate) / 1000) }
        }
        if let audio = player.selectedAudioTrack ?? player.audioTracks.first {
            result.fields["音频编码"] = audio.codecString
            result.fields["音频语言"] = audio.language
            if let channels = audio.channels, channels > 0 { result.fields["声道数"] = String(channels) }
            if let sampleRate = audio.sampleRate, sampleRate > 0 { result.fields["采样率"] = "\(sampleRate) Hz" }
            if audio.bitrate > 0 { result.fields["音频码率"] = String(format: "%.1f kbit/s", Double(audio.bitrate) / 1000) }
        }
        return result
    }

    public var downloadSample: EngineDownloadSample? {
        guard measuresNetworkInput, let player, let bytes = player.statistics?.readBytes,
              let count = Int64(exactly: bytes) else { return nil }
        return .init(counterID: downloadSessionID, bytes: count)
    }

    public var diagnosticMetrics: [EngineDiagnosticMetric] {
        guard let statistics = player?.statistics else { return [] }
        var metrics: [EngineDiagnosticMetric] = [
            .init("输入码率", Self.rate(statistics.inputBitrate)),
            .init("读取字节", Self.byteCount(statistics.readBytes)),
            .init("解复用字节", Self.byteCount(statistics.demuxReadBytes)),
            .init("解码视频帧", "\(statistics.decodedVideo)"),
            .init("显示视频帧", "\(statistics.displayedPictures)"),
            .init("迟到视频帧", "\(statistics.latePictures)"),
            .init("丢失视频帧", "\(statistics.lostPictures)"),
            .init("损坏数据包", "\(statistics.demuxCorrupted)"),
            .init("时间戳不连续", "\(statistics.demuxDiscontinuity)"),
            .init("已播放音频缓冲", "\(statistics.playedAudioBuffers)"),
            .init("丢失音频缓冲", "\(statistics.lostAudioBuffers)")
        ]
        let now = Date()
        if let previousDiagnosticSample {
            let elapsed = now.timeIntervalSince(previousDiagnosticSample.date)
            if elapsed > 0, statistics.displayedPictures >= previousDiagnosticSample.pictures {
                let fps = Double(statistics.displayedPictures - previousDiagnosticSample.pictures) / elapsed
                metrics.insert(.init("显示帧率", String(format: "%.1f fps", fps)), at: 4)
            }
        }
        self.previousDiagnosticSample = (now, statistics.displayedPictures)
        return metrics
    }
    private static func rate(_ kilobits: Float) -> String {
        guard kilobits.isFinite, kilobits >= 0 else { return "-" }
        return String(format: "%.1f Mb/s", kilobits / 1_000)
    }
    private static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
    public func load(url: URL, configuration: EngineConfiguration) async throws {
        measuresNetworkInput = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        downloadSessionID = UUID().uuidString
        let supportedHeaders = Set(["user-agent", "referer", "referrer", "cookie"])
        let unsupportedHeaders = configuration.requestHeaders.keys.filter { !supportedHeaders.contains($0.lowercased()) }
        guard unsupportedHeaders.isEmpty else {
            throw PlaybackCoreError.failed("SwiftVLC 当前无法附加自定义请求头：\(unsupportedHeaders.joined(separator: ", "))。正在尝试 AetherEngine。")
        }
        self.configuration = configuration
        let player = Player()
        self.player = player
        timelineEvents?.cancel()
        pendingSeekTime = nil
        let events = player.events
        timelineEvents = Task { @MainActor [weak self, weak player] in
            for await event in events {
                guard !Task.isCancelled, let self, let player, self.player === player else { return }
                if case .timeChanged(let time) = event, let target = self.pendingSeekTime {
                    // Native time, not the optimistically assigned currentTime,
                    // acknowledges the latest seek. Ignore outgoing old-clock events.
                    if abs(self.seconds(time) - target) < 1.5 { self.pendingSeekTime = nil }
                }
                if case .stateChanged(let state) = event, state == .error || state == .stopped {
                    self.pendingSeekTime = nil
                }
            }
        }
        installSurface(player)
        let media = try Media(url: url)
        for subtitle in configuration.externalSubtitles {
            try media.addSlave(from: subtitle.url, type: .subtitle)
        }
        media.addOption(configuration.decoder == .software ? ":avcodec-hw=none" : ":avcodec-hw=any")
        for (name, value) in configuration.requestHeaders {
            guard !value.contains("\r"), !value.contains("\n") else { continue }
            switch name.lowercased() {
            case "user-agent": media.addOption(":http-user-agent=\(value)")
            case "referer", "referrer": media.addOption(":http-referrer=\(value)")
            case "cookie": media.addOption(":http-cookie=\(value)")
            default: break
            }
        }
        media.addOption(":no-video-title-show")
        let networkCachingMilliseconds: Int? = url.isFileURL ? nil : 5_000
        if let networkCachingMilliseconds {
            media.addOption(":network-caching=\(networkCachingMilliseconds)")
        }
        // Open the complete input timeline. VLC's start-time input option can
        // expose the remaining input length as duration on some demuxers.
        // Restore progress with a normal absolute seek after input readiness.
        if !configuration.autoplay || configuration.position > 0 { media.addOption(":start-paused") }
        try player.play(media)
        // Readiness is asynchronous. Do not report success merely on play().
        // A large network buffer must be allowed to fill before the open timeout.
        let openTimeout = max(40.0, Double(networkCachingMilliseconds ?? 0) / 1_000 + 15)
        let deadline = ContinuousClock.now.advanced(by: .seconds(openTimeout))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            switch player.state {
            case .playing, .paused:
                if configuration.position > 0 {
                    // State readiness can precede seekability (especially HTTP).
                    // Keep waiting within the existing open timeout, rather than
                    // silently starting at zero or changing the input timeline.
                    guard player.isSeekable else {
                        try await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    try player.seek(to: .seconds(configuration.position), fast: false)
                    pendingSeekTime = configuration.position
                    seekClockDeadline = Date().addingTimeInterval(8)
                }
                configure(configuration)
                if !configuration.autoplay { player.pause() }
                else if configuration.position > 0 { try player.play() }
                return
            case .error: throw PlaybackCoreError.failed("SwiftVLC: 播放失败")
            default: break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PlaybackCoreError.failed("SwiftVLC: 打开媒体超时")
    }
    private func installSurface(_ player: Player) {
        let binding = Binding<PiPController?>(get: { [weak self] in self?.pip }, set: { [weak self] pip in
            self?.pip = pip
            pip?.onRestoreUserInterface = { [weak self] completion in
                guard let restore = self?.restoreUI else { completion(false); return }
                restore { success in completion(success) }
            }
        })
        let root = AnyView(PiPVideoView(player, controller: binding,
                                      startsAutomaticallyFromInline: configuration.automaticPiP,
                                      managesAudioSession: false)
            .id(configuration.automaticPiP).ignoresSafeArea())
        if let hosting { hosting.rootView = root }
        else {
            let hosting = UIHostingController(rootView: root)
            self.hosting = hosting
            hosting.view.backgroundColor = .black
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(hosting.view)
            NSLayoutConstraint.activate([
                hosting.view.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
                hosting.view.topAnchor.constraint(equalTo: surface.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
            ])
        }
        hasInstalledSurface = true
    }
    public func configure(_ configuration: EngineConfiguration) {
        let previous = self.configuration
        self.configuration = configuration
        guard let player else { return }
        player.isMuted = configuration.muted
        try? player.setPlaybackRate(PlaybackRate(configuration.rate))
        player.aspectRatio = configuration.fillsScreen && pip?.isActive != true ? .fill : .default
        player.setSubtitleScale(SubtitleScale(Float(configuration.subtitleFontSize / 22)))
        try? player.setSubtitleDelay(.seconds(configuration.subtitleDelay))
        if hasInstalledSurface && previous.automaticPiP != configuration.automaticPiP {
            if !configuration.automaticPiP { pip?.stop() }
            installSurface(player)
        }
    }
    public func play() throws { try player?.play() }
    public func pause() { player?.pause() }
    public func seek(to seconds: Double) async throws {
        try await seek(to: seconds, fast: false)
    }
    public func seek(to seconds: Double, fast: Bool) async throws {
        guard let player else { throw PlaybackCoreError.cancelled }
        let stream = player.events
        let wasPaused = !player.isPlaybackRequestedActive
        try player.seek(to: .seconds(seconds), fast: fast)
        pendingSeekTime = seconds
        seekClockDeadline = Date().addingTimeInterval(8)
        // SwiftVLC 1.0.0 explicitly permits no timeChanged callback while
        // paused. This is request acceptance, not proof of a decoded frame.
        // Waiting here deadlocks scrub previews behind an eight-second timeout
        // and prevents the final seek from reaching the resume command.
        if wasPaused || fast { try Task.checkCancellation(); return }
        // currentTime is optimistically assigned by SwiftVLC; require native
        // timeChanged acknowledgement instead of trusting that shadow value.
        let landed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in stream {
                    if Task.isCancelled { return false }
                    if case .timeChanged(let time) = event {
                        let value = Double(time.components.seconds) + Double(time.components.attoseconds) / 1e18
                        if abs(value - seconds) < 1.5 { return true }
                    }
                }
                return false
            }
            group.addTask { try? await Task.sleep(for: .seconds(8)); return false }
            let landed = await group.next() ?? false
            group.cancelAll()
            return landed
        }
        guard landed else { pendingSeekTime = nil; throw PlaybackCoreError.failed("SwiftVLC: 定位未完成") }
    }
    public func shutdown() async {
        timelineEvents?.cancel(); timelineEvents = nil; pendingSeekTime = nil
        pip?.onRestoreUserInterface = nil; pip?.stop(); pip = nil
        let old = player
        player = nil
        // Wait for native decoder and output threads, not just async stop().
        await old?.shutdown()
        hosting?.view.removeFromSuperview(); hosting = nil; hasInstalledSurface = false
    }
    public func selectAudio(_ id: String) { player?.selectedAudioTrack = player?.audioTracks.first { $0.id == id } }
    public func selectSubtitle(_ id: String?) {
        guard let player else { return }
        player.selectedSubtitleTrack = id.flatMap { requestedID in
            player.subtitleTracks.first { $0.id == requestedID }
        }
    }
    public func setPiPActive(_ active: Bool) {}
    public func startPiP() { player?.aspectRatio = .default; pip?.start() }
    public func stopPiP() { pip?.stop() }
    private func seconds(_ duration: Duration) -> Double { Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
}

public enum VLCMediaProbe {
    public static func inspect(_ url: URL) async throws -> MediaProbe {
        let media = try Media(url: url)
        let metadata = try await media.parse(timeout: .seconds(10))
        let videos = media.tracks().filter { $0.type == .video }
        var result = MediaProbe()
        result.hasVideo = !videos.isEmpty
        if let video = videos.first { result.width = video.width ?? 0; result.height = video.height ?? 0; result.fields["视频编码"] = video.codecString }
        if let duration = metadata.duration { result.duration = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
        return result
    }
    public static func thumbnail(_ url: URL) async throws -> Data {
        let media = try Media(url: url)
        return try await media.thumbnail(at: .zero, width: 600, seekMode: .fast)
    }
}
