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
    public var restoreUI: ((@escaping (Bool) -> Void) -> Void)?
    public var view: UIView { surface }
    // SwiftVLC owns the native AVKit delegate. Do not replace it from the App.
    public var nativePiPController: AVPictureInPictureController? { nil }
    public init() { surface.backgroundColor = .black }
    public var snapshot: EngineSnapshot {
        var result = EngineSnapshot()
        guard let player else { return result }
        switch player.state {
        case .idle, .stopped, .stopping: result.phase = player.didReachEnd ? .ended : .idle
        case .opening, .buffering: result.phase = .loading
        case .playing: result.phase = player.isPlaying ? .playing : .paused
        case .paused: result.phase = .paused
        case .error: result.phase = .failed("SwiftVLC: 播放失败")
        }
        result.time = seconds(player.currentTime)
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
    public func load(url: URL, configuration: EngineConfiguration) async throws {
        self.configuration = configuration
        let player = Player()
        self.player = player
        installSurface(player)
        let media = try Media(url: url)
        media.addOption(configuration.decoder == .software ? ":avcodec-hw=none" : ":avcodec-hw=any")
        media.addOption(":no-video-title-show")
        if configuration.position > 0 { media.addOption(":start-time=\(configuration.position)") }
        if !configuration.autoplay { media.addOption(":start-paused") }
        try player.play(media)
        // Readiness is asynchronous. Do not report success merely on play().
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            switch player.state {
            case .playing, .paused:
                player.selectedSubtitleTrack = nil
                configure(configuration)
                if !configuration.autoplay { player.pause() }
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
        if hasInstalledSurface && previous.automaticPiP != configuration.automaticPiP {
            if !configuration.automaticPiP { pip?.stop() }
            installSurface(player)
        }
    }
    public func play() throws { try player?.play() }
    public func pause() { player?.pause() }
    public func seek(to seconds: Double) async throws {
        guard let player else { throw PlaybackCoreError.cancelled }
        let stream = player.events
        try player.seek(to: .seconds(seconds), fast: false)
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
        guard landed else { throw PlaybackCoreError.failed("SwiftVLC: 定位未完成") }
    }
    public func shutdown() async {
        pip?.onRestoreUserInterface = nil; pip?.stop(); pip = nil
        let old = player
        player = nil
        // Wait for native decoder and output threads, not just async stop().
        await old?.shutdown()
        hosting?.view.removeFromSuperview(); hosting = nil; hasInstalledSurface = false
    }
    public func selectAudio(_ id: String) { player?.selectedAudioTrack = player?.audioTracks.first { $0.id == id } }
    public func selectSubtitle(_ id: String?) { player?.selectedSubtitleTrack = player?.subtitleTracks.first { $0.id == id } }
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
