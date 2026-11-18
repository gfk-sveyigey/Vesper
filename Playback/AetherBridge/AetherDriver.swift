import Foundation
import UIKit
import AVKit
import PlaybackContracts
internal import AetherEngine

/// AetherEngine and its complete decode dependency closure link ONLY here.
@MainActor public final class AetherDriver: PlaybackDriver {
    public let id: EngineID = .aether
    private var engine: AetherEngine?
    private let surface = AetherPlayerView(frame: .zero)
    private var configuration = EngineConfiguration()
    private var pip: AVPictureInPictureController?
    private weak var pipLayer: AVPlayerLayer?
    private weak var pipSampleLayer: AVSampleBufferDisplayLayer?
    public var restoreUI: ((@escaping (Bool) -> Void) -> Void)?
    public var view: UIView { surface }
    public init() {}
    public var nativePiPController: AVPictureInPictureController? {
        guard let engine else { return nil }
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
        result.buffered = engine.currentAVPlayer?.currentItem?.loadedTimeRanges.compactMap {
            CMTimeRangeGetEnd($0.timeRangeValue).seconds
        }.max() ?? result.time
        result.seekable = result.duration > 0
        if let decoder = engine.activeVideoDecoder {
            if decoder.contains("(SW)") { result.actualDecoder = .software }
            else if decoder.contains("(HW)") { result.actualDecoder = .hardware }
        }
        if engine.playbackBackend == .native { result.actualDecoder = .hardware }
        result.audio = engine.audioTracks.map { .init(id: String($0.id), name: $0.name, language: $0.language, codec: $0.codec, selected: $0.id == engine.activeAudioTrackIndex) }
        result.subtitles = engine.subtitleTracks.map { .init(id: String($0.id), name: $0.name, language: $0.language, codec: $0.codec, selected: $0.id == engine.activeSubtitleTrackIndex) }
        let cues = engine.subtitleCues.filter { $0.startTime <= result.time && $0.endTime >= result.time }
        result.subtitleText = cues.compactMap { cue -> String? in
            switch cue.body { case .text(let text): text; case .richText(let runs): runs.map(\.text).joined(); case .image: nil }
        }.joined(separator: "\n")
        result.subtitleImage = cues.compactMap { cue -> UIImage? in
            if case .image(let image) = cue.body { return UIImage(cgImage: image.cgImage) }; return nil
        }.first
        if let pip = nativePiPController { result.pipPossible = pip.isPictureInPicturePossible; result.pipActive = pip.isPictureInPictureActive }
        return result
    }
    public func load(url: URL, configuration: EngineConfiguration) async throws {
        let engine = try AetherEngine()
        self.engine = engine
        engine.deactivatesAudioSessionOnStop = false
        engine.bind(view: surface)
        self.configuration = configuration
        configure(configuration)
        var options = LoadOptions()
        options.autoplay = configuration.autoplay
        options.preferredDecodePath = configuration.decoder == .software ? .software : .automatic
        _ = try await engine.load(url: url, startPosition: configuration.position, options: options)
        try Task.checkCancellation()
        engine.clearSubtitle()
        configure(configuration)
    }
    public func configure(_ configuration: EngineConfiguration) {
        self.configuration = configuration
        engine?.backgroundPlaybackEnabled = configuration.backgroundEnabled
        engine?.volume = configuration.muted ? 0 : 1
        engine?.setRate(configuration.rate)
        engine?.currentAVPlayer?.allowsExternalPlayback = true
        engine?.videoGravity = configuration.fillsScreen && pip?.isPictureInPictureActive != true ? .resizeAspectFill : .resizeAspect
        pip?.canStartPictureInPictureAutomaticallyFromInline = configuration.automaticPiP
    }
    public func play() throws { engine?.play() }
    public func pause() { engine?.pause() }
    public func seek(to seconds: Double) async throws { guard let engine else { throw PlaybackCoreError.cancelled }; await engine.seek(to: seconds, exact: true); try Task.checkCancellation() }
    public func shutdown() async {
        pip?.delegate = nil; pip?.stopPictureInPicture(); pip = nil; pipLayer = nil; pipSampleLayer = nil
        engine?.stop(finalTeardown: true)
        await engine?.releaseScrubPreviewDecoders()
        engine = nil
    }
    public func selectAudio(_ id: String) { if let index = Int(id) { engine?.selectAudioTrack(index: index) } }
    public func selectSubtitle(_ id: String?) { if let id, let index = Int(id) { engine?.selectSubtitleTrack(index: index) } else { engine?.clearSubtitle() } }
    public func setPiPActive(_ active: Bool) {
        engine?.pictureInPictureActive = active
        engine?.videoGravity = active || !configuration.fillsScreen ? .resizeAspect : .resizeAspectFill
    }
    public func startPiP() {
        engine?.videoGravity = .resizeAspect
        nativePiPController?.startPictureInPicture()
    }
    public func stopPiP() { pip?.stopPictureInPicture() }
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
