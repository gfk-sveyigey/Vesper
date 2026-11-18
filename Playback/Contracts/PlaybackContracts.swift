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
    public init() {}
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
    func shutdown() async
    func configure(_ configuration: EngineConfiguration)
    func selectAudio(_ id: String)
    func selectSubtitle(_ id: String?)
    func setPiPActive(_ active: Bool)
    func startPiP()
    func stopPiP()
}
public enum PlaybackCoreError: LocalizedError {
    case failed(String), cancelled
    public var errorDescription: String? {
        switch self { case .failed(let message): message; case .cancelled: "Playback cancelled" }
    }
}
