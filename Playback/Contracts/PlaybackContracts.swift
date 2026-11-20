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
    public init(id: String, name: String, language: String? = nil, codec: String? = nil, selected: Bool = false) {
        self.id = id; self.name = name; self.language = language; self.codec = codec; self.selected = selected
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
    public var subtitleBackground = true
    public var subtitleDelay: Double = 0
    /// Optional Emby compressed-media cache budget, in bytes. VLC converts it to a time buffer.
    public var preloadCacheLimitBytes: Int? = nil
    /// Total bitrate of the selected stream, in bits per second.
    public var mediaBitRate: Double? = nil
    public var requestHeaders: [String: String] = [:]
    public var externalSubtitles: [EngineExternalSubtitle] = []
    public init() {}
}

public enum PlaybackCacheSizing {
    /// VLC's network-caching option accepts 0...60,000 ms. Use 20 Mbps when
    /// the server supplies no usable bitrate; this remains a time-based buffer.
    public static func vlcMilliseconds(byteLimit: Int, bitRate: Double?) -> Int {
        let rate = bitRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 20_000_000
        let milliseconds = Double(max(0, byteLimit)) * 8_000 / rate
        return Int(min(60_000, max(1, milliseconds.rounded(.down))))
    }
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
    public var seekable = false
    public var actualDecoder: DecodePreference?
    public var audio: [EngineTrack] = []
    public var subtitles: [EngineTrack] = []
    public var subtitleText = ""
    public var subtitleImage: UIImage?
    public var pipPossible = false
    public var pipActive = false
    public init() {}
}
@MainActor public protocol PlaybackDriver: AnyObject {
    var id: EngineID { get }
    var view: UIView { get }
    var snapshot: EngineSnapshot { get }
    var nativePiPController: AVPictureInPictureController? { get }
    var restoreUI: ((@escaping (Bool) -> Void) -> Void)? { get set }
    func load(url: URL, configuration: EngineConfiguration) async throws
    func play() throws
    func pause()
    func seek(to seconds: Double) async throws
    func seek(to seconds: Double, fast: Bool) async throws
    func shutdown() async
    func configure(_ configuration: EngineConfiguration)
    func selectAudio(_ id: String)
    func selectSubtitle(_ id: String?)
    func setPiPActive(_ active: Bool)
    func startPiP()
    func stopPiP()
}
extension PlaybackDriver {
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
