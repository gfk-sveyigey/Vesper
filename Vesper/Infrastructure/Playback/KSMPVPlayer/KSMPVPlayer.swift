//
//  KSMPVPlayer.swift
//
//
//  Created by kintan on 5/2/24.
//

import AVFoundation
import AVKit
import CoreGraphics
import Dispatch
import Foundation
@preconcurrency import KSPlayer
import libmpv
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@MainActor
public final class KSMPVPlayer: MPVHandle, @unchecked Sendable {
    public weak var delegate: MediaPlayerDelegate?
    public var allowsExternalPlayback: Bool = false
    public var usesExternalPlaybackWhileExternalScreenIsActive: Bool = false
    public private(set) var isReadyToPlay = false
    public var currentPlaybackTime: TimeInterval = 0

    public private(set) var loadState = MediaLoadState.idle {
        didSet {
            if loadState != oldValue {
                playOrPause()
            }
        }
    }

    public private(set) var playbackState = MediaPlaybackState.idle {
        didSet {
            if playbackState != oldValue {
                playOrPause()
            }
        }
    }

    public var dynamicInfo: DynamicInfo? { nil }

    public var seekable: Bool = false
    public var duration: TimeInterval = 0
    public var fileSize: Double = 0
    public var naturalSize: CGSize = .zero
    private lazy var _playbackCoordinator: Any? = {
        if #available(macOS 12.0, iOS 15.0, tvOS 15.0, *) {
            let coordinator = AVDelegatingPlaybackCoordinator(playbackControlDelegate: self)
            coordinator.suspensionReasonsThatTriggerWaiting = [.stallRecovery]
            return coordinator
        } else {
            return nil
        }
    }()

    private var tracks = [MPVTrack]()
    private var url: URL
    private let options: KSOptions
    @MainActor
    public var pipController: KSPictureInPictureController?
    @MainActor
    public required init(url: URL, options: KSOptions) {
        self.url = url
        self.options = options
        super.init(options: options)
    }

    override public func handle(event: mpv_event) {
        super.handle(event: event)
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            sourceDidOpened()
        case MPV_EVENT_END_FILE:
            let end = event.data.load(as: mpv_event_end_file.self)
            guard end.reason == MPV_END_FILE_REASON_EOF || end.reason == MPV_END_FILE_REASON_ERROR else { return }
            let error = end.reason == MPV_END_FILE_REASON_ERROR ? NSError(domain: "mpv", code: Int(end.error)) : nil
            runOnMainThread { [weak self] in
                guard let self else {
                    return
                }
                delegate?.finish(player: self, error: error)
            }
        default:
            break
        }
    }

    override public func change(property: mpv_event_property, name: String) {
        super.change(property: property, name: name)
        switch name {
        case MPVOption.PlaybackControl.pause:
            if let paused = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee {
                playbackState = paused != 0 ? .paused : .playing
            }
        case MPVProperty.pausedForCache:
            if let paused = UnsafePointer<Int32>(OpaquePointer(property.data))?.pointee {
                loadState = paused != 0 ? .loading : .playable
            }
        case MPVProperty.timePos:
            if let time = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
                currentPlaybackTime = time
            }
        default:
            break
        }
    }

    private func sourceDidOpened() {
        isReadyToPlay = true
        seekable = getFlag(MPVProperty.seekable)
        duration = getDouble(MPVProperty.duration)
        fileSize = Double(getInt(MPVProperty.fileSize))
        naturalSize = CGSize(width: getInt(MPVProperty.width), height: getInt(MPVProperty.height))
        let trackCount = getInt(MPVProperty.trackListCount)
        tracks = (0 ..< trackCount).compactMap { index in
            guard let trackType = getString(MPVProperty.trackListNType(index)), let mediaType = trackType.mpvToMediaType else {
                return nil
            }
            return MPVTrack(
                handle: self, trackID: Int32(getInt(MPVProperty.trackListNId(index))),
                name: getString(MPVProperty.trackListNTitle(index)) ?? "",
                mediaType: mediaType,
                nominalFrameRate: Float(getDouble(MPVProperty.trackListNDemuxFps(index))),
                bitRate: 0,
                bitDepth: 0,
                isImageSubtitle: false,
                rotation: 0,
                fieldOrder: .unknown,
                languageCode: getString(MPVProperty.trackListNLang(index)),
                description: getString(MPVProperty.trackListNDecoderDesc(index)) ?? ""
            )
        }
        runOnMainThread { [weak self] in
            guard let self else {
                return
            }
            delegate?.readyToPlay(player: self)
        }
    }

    private func playOrPause() {
        runOnMainThread { [weak self] in
            guard let self else { return }
            delegate?.changeLoadState(player: self)
        }
    }

#if DEBUG
    deinit {
        KSLog("")
    }
#endif
}

extension KSMPVPlayer: @preconcurrency MediaPlayerProtocol {

    public var view: UIView? {
        metalView
    }

    public var playableTime: TimeInterval {
        duration
    }

    public var isMuted: Bool {
        get {
            getFlag(MPVOption.Audio.mute)
        }
        set(newValue) {
            setFlag(MPVOption.Audio.mute, newValue)
        }
    }

    public var playbackRate: Float {
        get {
            Float(getDouble(MPVOption.PlaybackControl.speed))
        }
        set(newValue) {
            setDouble(MPVOption.PlaybackControl.speed, Double(newValue))
        }
    }

    public var playbackVolume: Float {
        get {
            Float(getDouble(MPVOption.Audio.volume) / 100)
        }
        set(newValue) {
            setDouble(MPVOption.Audio.volume, Double(newValue) * 100)
        }
    }

    public var subtitleDataSouce: SubtitleDataSouce? { nil }

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
    public var playbackCoordinator: AVPlaybackCoordinator {
        // swiftlint:disable force_cast
        _playbackCoordinator as! AVPlaybackCoordinator
        // swiftlint:enable force_cast
    }

    public func replace(url: URL, options _: KSOptions) {
        self.url = url
        reset()
    }

    public var isPlaying: Bool { playbackState == .playing }
    public var isExternalPlaybackActive: Bool { false }
    public var usingHardwareDecoder: Bool {
        guard let decoder = getString(MPVProperty.hwdecCurrent) else { return false }
        return decoder != "no" && !decoder.isEmpty
    }
    public var contentMode: UIView.ContentMode = .scaleAspectFit {
        didSet { setDouble("panscan", contentMode == .scaleAspectFill ? 1 : 0) }
    }
    public func disableSubtitles() { setString(MPVOption.TrackSelection.sid, "no") }

    public func play() {
        playbackState = .playing
        setFlagAsync(MPVOption.PlaybackControl.pause, false)
    }

    public func pause() {
        playbackState = .paused
        setFlagAsync(MPVOption.PlaybackControl.pause, true)
    }

    public func enterBackground() {}

    public func enterForeground() {}

    public func thumbnailImageAtCurrentTime() async -> CGImage? {
        nil
    }

    public func tracks(mediaType: AVMediaType) -> [any KSPlayer.MediaPlayerTrack] {
        tracks.filter { $0.mediaType == mediaType }
    }

    public func select(track: some KSPlayer.MediaPlayerTrack) { track.isEnabled = true }

    public var chapters: [KSPlayer.Chapter] {
        []
    }

    public func prepareToPlay() {
        setDouble(MPVOption.PlaybackControl.speed, Double(options.startPlayRate))
        loadFile(url: url, options: options.startPlayTime > 0 ? ["start=\(options.startPlayTime)"] : [])
    }

    public func shutdown() {
        destroyHandle()
        isReadyToPlay = false
        playbackState = .stopped
        loadState = .idle
    }

    public func reset() {
        _ = command(.stop)
    }

    public func seek(time: TimeInterval, completion: @escaping (Bool) -> Void) {
        let wasPlaying = isPlaying
        playbackState = .seeking
        let code = command(.seek, args: [String(time), "absolute+exact"])
        playbackState = wasPlaying ? .playing : .paused
        runOnMainThread {
            completion(code == 0)
        }
    }

    public func configPIP() {}
}

extension KSMPVPlayer {
    private func loadFile(url: URL, options: [String] = []) {
        let urlString: String
        if url.isFileURL {
            urlString = url.path
        } else {
            urlString = url.absoluteString
        }
        var args = [urlString]
        if !options.isEmpty {
            args.append(options.joined(separator: ","))
        }
        _ = command(.loadfile, args: args)
    }
}

@available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
extension KSMPVPlayer: AVPlaybackCoordinatorPlaybackControlDelegate {
    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue playCommand: AVDelegatingPlaybackCoordinatorPlayCommand) async {
        guard await playCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            return
        }
        if playbackState != .playing {
            await play()
        }
    }

    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue pauseCommand: AVDelegatingPlaybackCoordinatorPauseCommand) async {
        guard await pauseCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            return
        }
        if playbackState != .paused {
            await pause()
        }
    }

    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue seekCommand: AVDelegatingPlaybackCoordinatorSeekCommand) async {
        guard await seekCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier else {
            return
        }
        let seekTime = fmod(seekCommand.itemTime.seconds, duration)
        if abs(currentPlaybackTime - seekTime) < CGFLOAT_EPSILON {
            return
        }
        await _ = seek(time: seekTime)
    }

    public func playbackCoordinator(_: AVDelegatingPlaybackCoordinator, didIssue bufferingCommand: AVDelegatingPlaybackCoordinatorBufferingCommand) async {
        guard await bufferingCommand.expectedCurrentItemIdentifier == (playbackCoordinator as? AVDelegatingPlaybackCoordinator)?.currentItemIdentifier, loadState != .playable, let countDown = bufferingCommand.completionDueDate?.timeIntervalSinceNow else {
            return
        }
        try? await Task.sleep(nanoseconds: UInt64(countDown * 1_000_000_000))
    }
}

@MainActor
public final class MPVTrack: @preconcurrency MediaPlayerTrack, @unchecked Sendable {
    private weak let handle: MPVHandle?
    public let subtitleID: String
    public let delay: TimeInterval = 0
    public var name: String
    public var mediaType: AVMediaType
    public var description: String
    public var nominalFrameRate: Float
    public var bitRate: Int64
    public var trackID: Int32
    public var bitDepth: Int32
    public let reorderSize: Int32 = 0
    public var rotation: Int16
    public var fieldOrder: KSPlayer.FFmpegFieldOrder
    public var isImageSubtitle: Bool
    public var languageCode: String?
    public var formatDescription: CMFormatDescription?
    public var dovi: KSPlayer.DOVIDecoderConfigurationRecord?
    public var isSelected: Bool {
        get {
            isEnabled
        }
        set {
            isEnabled = newValue
        }
    }

    public var isEnabled: Bool {
        get {
            handle?.getInt(mediaType == .audio ? MPVOption.TrackSelection.aid : (mediaType == .video ? MPVOption.TrackSelection.vid : MPVOption.TrackSelection.sid)) == Int(trackID)
        }
        set {
            if newValue {
                let name: String
                if mediaType == .video {
                    name = MPVOption.TrackSelection.vid
                } else if mediaType == .audio {
                    name = MPVOption.TrackSelection.aid
                } else {
                    name = MPVOption.TrackSelection.sid
                }
                handle?.setInt(name, Int(trackID))
            }
        }
    }

    init(handle: MPVHandle, trackID: Int32, name: String, mediaType: AVMediaType, nominalFrameRate: Float, bitRate: Int64, bitDepth: Int32, isImageSubtitle: Bool, rotation: Int16, fieldOrder: KSPlayer.FFmpegFieldOrder, languageCode: String?, description: String) {
        self.handle = handle
        self.trackID = trackID
        subtitleID = String(trackID)
        var name = name
        if name.isEmpty, let languageCode {
            name += languageCode
        }
        self.name = name
        self.mediaType = mediaType
        self.nominalFrameRate = nominalFrameRate
        self.bitRate = bitRate
        self.bitDepth = bitDepth
        self.isImageSubtitle = isImageSubtitle
        self.rotation = rotation
        self.fieldOrder = fieldOrder
        self.languageCode = languageCode
        var description = description
        if description.isEmpty, let languageCode {
            description += languageCode
        }
        self.description = description
    }


}

extension String {
    var mpvToMediaType: AVMediaType? {
        switch self {
        case "video":
            return AVMediaType.video
        case "audio":
            return AVMediaType.audio
        case "sub":
            return AVMediaType.subtitle
        default:
            return nil
        }
    }
}
