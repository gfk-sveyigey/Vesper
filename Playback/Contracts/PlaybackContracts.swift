import Foundation
import UIKit
import AVKit

public enum EngineID: String, Sendable, CaseIterable { case aether, vlc }
public enum DecodePreference: String, Sendable { case hardware, software }
public enum EnginePhase: Sendable, Equatable { case idle, loading, playing, paused, ended, failed(String) }

public struct EngineTrack: Sendable, Equatable {
    public let id: String
    public let name: String
    public let language: String?
    public let codec: String?
    public let selected: Bool
    public let sourceTitle: String?
    public let channels: Int?
    public init(id: String, name: String, language: String? = nil, codec: String? = nil, selected: Bool = false,
                sourceTitle: String? = nil, channels: Int? = nil) {
        self.id = id; self.name = name; self.language = language; self.codec = codec; self.selected = selected
        self.sourceTitle = sourceTitle; self.channels = channels
    }
}

public struct EngineDiagnosticMetric: Identifiable, Sendable, Equatable {
    public let title: String
    public let value: String
    public var id: String { title }

    public init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }
}
/// Cumulative input bytes, with a key that changes when the measured link changes.
public struct EngineDownloadSample: Sendable {
    public let counterID: String
    public let bytes: Int64
    public init(counterID: String, bytes: Int64) {
        self.counterID = counterID
        self.bytes = bytes
    }
}

/// A short wall-clock mean over arriving source bytes, including idle time.
public struct DownloadSpeedSampler {
    private var counterID: String?
    private var samples: [(time: TimeInterval, bytes: Int64)] = []
    public init() {}

    public static func megabytesPerSecond(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        return String(format: "%.2f MB/s", bytesPerSecond / 1_000_000)
    }

    public mutating func update(_ sample: EngineDownloadSample?, at time: TimeInterval) -> Double? {
        guard let sample, sample.bytes >= 0, time.isFinite else {
            counterID = nil
            samples.removeAll()
            return nil
        }
        if counterID != sample.counterID {
            samples.removeAll()
        }
        if let last = samples.last,
           time <= last.time || time - last.time > 5 || sample.bytes < last.bytes {
            samples.removeAll()
        }
        counterID = sample.counterID
        samples.append((time, sample.bytes))
        while samples.count > 2 && time - samples[1].time >= 2 {
            samples.removeFirst()
        }
        guard let first = samples.first, time > first.time else { return nil }
        return Double(sample.bytes - first.bytes) / (time - first.time)
    }
}

public struct MediaProbe: Sendable {
    public var duration: Double = 0
    public var width: Int = 0
    public var height: Int = 0
    public var hasVideo = false
    public var container: String?
    public var fields: [String: String] = [:]
    public init() {}
}

public enum VideoViewportLayout {
    public static func contentRect(sourceSize: CGSize?, viewport: CGRect, fillsScreen: Bool) -> CGRect {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return .zero }
        guard !fillsScreen,
              let sourceSize,
              sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0 else { return viewport }

        let scale = min(viewport.width / sourceSize.width, viewport.height / sourceSize.height)
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(x: viewport.midX - size.width / 2,
                      y: viewport.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }
}

public struct EngineConfiguration: Sendable {
    public var decoder: DecodePreference = .hardware
    public var position: Double = 0
    public var autoplay = true
    public var rate: Float = 1
    public var muted = false
    public var fillsScreen = false
    public var backgroundEnabled = true
    public var automaticPiP = false
    public var subtitleFontSize: Double = 22
    public var subtitleDelay: Double = 0
    /// Optional Emby compressed-media cache budget, in bytes.
    public var preloadCacheLimitBytes: Int? = nil
    public var requestHeaders: [String: String] = [:]
    public var externalSubtitles: [EngineExternalSubtitle] = []
    public init() {}
}

public struct EngineExternalSubtitle: Sendable {
    public let url: URL
    public let name: String
    public let language: String?
    public let format: String
    public let headers: [String: String]
    public init(url: URL, name: String, language: String?, format: String, headers: [String: String] = [:]) {
        self.url = url; self.name = name; self.language = language; self.format = format; self.headers = headers
    }
}
/// Value-only state; no FFmpeg/VLC pointers or upstream Swift types cross a bridge.
@MainActor public struct EngineSnapshot {
    public var phase: EnginePhase = .idle
    public var time: Double = 0
    public var duration: Double = 0
    public var buffered: Double = 0
    /// Cached media ranges on the timeline. Empty means the engine only exposes a frontier.
    public var bufferedRanges: [ClosedRange<Double>] = []
    public var seekable = false
    public var actualDecoder: DecodePreference?
    public var audio: [EngineTrack] = []
    public var subtitles: [EngineTrack] = []
    public var subtitleText = ""
    public var subtitleImage: UIImage?
    public var pipPossible = false
    public var pipActive = false
    /// The source is retained but its background video pipeline was released.
    /// The host must rebuild before seeking or sending another play command.
    public var requiresForegroundReload = false
    public init() {}
}
@MainActor public protocol PlaybackDriver: AnyObject {
    var id: EngineID { get }
    var view: UIView { get }
    var snapshot: EngineSnapshot { get }
    var diagnosticMetrics: [EngineDiagnosticMetric] { get }
    var downloadSample: EngineDownloadSample? { get }
    var mediaInformation: MediaProbe? { get }
    var nativePiPController: AVPictureInPictureController? { get }
    var restoreUI: ((@escaping (Bool) -> Void) -> Void)? { get set }
    func load(url: URL, configuration: EngineConfiguration) async throws
    func play() throws
    func pause()
    func seek(to seconds: Double) async throws
    func seek(to seconds: Double, fast: Bool) async throws
    func scrubPreview(at seconds: Double) async -> UIImage?
    func shutdown() async
    func configure(_ configuration: EngineConfiguration)
    func selectAudio(_ id: String)
    func selectSubtitle(_ id: String?)
    func setPiPActive(_ active: Bool)
    func preparePiP()
    func startPiP()
    func stopPiP()
}
extension PlaybackDriver {
    public var diagnosticMetrics: [EngineDiagnosticMetric] { [] }
    public var downloadSample: EngineDownloadSample? { nil }
    public var mediaInformation: MediaProbe? { nil }
    public func preparePiP() {}
    public func scrubPreview(at seconds: Double) async -> UIImage? { nil }
    public func seek(to seconds: Double, fast: Bool) async throws {
        try await seek(to: seconds)
    }
}
public enum PlaybackCoreError: LocalizedError {
    case failed(String), cancelled
    public var errorDescription: String? {
        switch self { case .failed(let message): message; case .cancelled: "Playback cancelled" }
    }
}
