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

    private var backgroundVideoID: Int?
    public var contentMode: UIView.ContentMode = .scaleAspectFit {
        didSet { setDouble("panscan", contentMode == .scaleAspectFill ? 1 : 0) }
    }
    private var reachedEnd = false
    private var hasRequestedLoad = false
    private var seekCompletion: ((Bool) -> Void)?
    private var seekTimeout: Task<Void, Never>?
    private var muted = false
    private var rate: Float = 1
    private var volume: Float = 1
    private var tracks = [MPVTrack]()
    private var url: URL
    private var options: KSOptions
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
        case MPV_EVENT_PLAYBACK_RESTART:
            completeSeek(true)
            renderView?.setNeedsDisplay()
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let end = data.load(as: mpv_event_end_file.self)
            guard end.reason == MPV_END_FILE_REASON_EOF || end.reason == MPV_END_FILE_REASON_ERROR else { return }
            let error = end.reason == MPV_END_FILE_REASON_ERROR ? playbackError(end.error, stage: "load/playback") : nil
            completeSeek(false)
            runOnMainThread { [weak self] in
                guard let self else {
                    return
                }
                if error != nil || !reachedEnd {
                    reachedEnd = true
                    delegate?.finish(player: self, error: error)
                }
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
        case "eof-reached":
            if getFlag("eof-reached"), !reachedEnd, isReadyToPlay {
                reachedEnd = true
                delegate?.finish(player: self, error: nil)
            }
        case "duration":
            if let data = property.data {
                let value = data.load(as: Double.self)
                duration = value.isFinite ? max(0, value) : 0
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
        reachedEnd = false
        isReadyToPlay = true
        seekable = getFlag(MPVProperty.seekable)
        duration = max(0, getDouble(MPVProperty.duration))
        AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [KSMPVPlayer] 已加载，duration=\(duration)，hwdec=\(getString(MPVProperty.hwdecCurrent) ?? "unknown")")
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
            setDouble("panscan", contentMode == .scaleAspectFill ? 1 : 0)
            loadState = .playable
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
        videoView
    }

    public var playableTime: TimeInterval {
        duration
    }

    public var isMuted: Bool {
        get {
            muted
        }
        set(newValue) {
            muted = newValue
            setFlag(MPVOption.Audio.mute, newValue)
        }
    }

    public var playbackRate: Float {
        get {
            rate
        }
        set(newValue) {
            rate = newValue.isFinite ? max(0.25, min(4, newValue)) : 1
            setDouble(MPVOption.PlaybackControl.speed, Double(rate))
        }
    }

    public var playbackVolume: Float {
        get {
            volume
        }
        set(newValue) {
            volume = newValue.isFinite ? max(0, min(1, newValue)) : 1
            setDouble(MPVOption.Audio.volume, Double(volume) * 100)
        }
    }

    public var subtitleDataSouce: SubtitleDataSouce? { nil }

    @available(macOS 12.0, iOS 15.0, tvOS 15.0, *)
    public var playbackCoordinator: AVPlaybackCoordinator {
        // swiftlint:disable force_cast
        _playbackCoordinator as! AVPlaybackCoordinator
        // swiftlint:enable force_cast
    }

    public func replace(url: URL, options: KSOptions) {
        shutdown()
        self.url = url
        self.options = options
        rate = options.startPlayRate
    }

    public var isPlaying: Bool { playbackState == .playing }
    public var isExternalPlaybackActive: Bool { false }
    public var usingHardwareDecoder: Bool {
        guard let decoder = getString(MPVProperty.hwdecCurrent) else { return false }
        return decoder != "no" && !decoder.isEmpty
    }
    public func disableSubtitles() { setString(MPVOption.TrackSelection.sid, "no") }

    public func play() {
        if !hasRequestedLoad { prepareToPlay() }
        guard initializationStatus >= 0 else { return }
        playbackState = .playing
        setFlagAsync(MPVOption.PlaybackControl.pause, false)
    }

    public func pause() {
        playbackState = .paused
        setFlagAsync(MPVOption.PlaybackControl.pause, true)
    }

    public func enterBackground() {
        setRenderingInBackground(true)
        guard backgroundVideoID == nil else { return }
        backgroundVideoID = getInt(MPVOption.TrackSelection.vid)
        setString(MPVOption.TrackSelection.vid, "no")
    }

    public func enterForeground() {
        setRenderingInBackground(false)
        if let id = backgroundVideoID {
            backgroundVideoID = nil
            if id > 0 { setInt(MPVOption.TrackSelection.vid, id) }
            else { setString(MPVOption.TrackSelection.vid, "auto") }
        }
    }

    public func thumbnailImageAtCurrentTime() async -> CGImage? {
        guard isReadyToPlay, UIApplication.shared.applicationState != .background,
              let renderView, renderView.window != nil else { return nil }
        return renderView.snapshot.cgImage
    }

    public func tracks(mediaType: AVMediaType) -> [any KSPlayer.MediaPlayerTrack] {
        tracks.filter { $0.mediaType == mediaType }
    }

    public func select(track: some KSPlayer.MediaPlayerTrack) { track.isEnabled = true }

    public var chapters: [KSPlayer.Chapter] {
        []
    }

    public func prepareToPlay() {
        guard !hasRequestedLoad else { return }
        if mpv == nil { initializeHandle(options: options) }
        guard initializationStatus >= 0 else {
            delegate?.finish(player: self, error: playbackError(initializationStatus, stage: "initialize"))
            return
        }
        hasRequestedLoad = true
        reachedEnd = false
        loadState = .loading
        playbackRate = options.startPlayRate
        setFlag("mute", muted)
        setDouble("volume", Double(volume) * 100)
        if options.startPlayTime > 0 { setString("start", String(options.startPlayTime)) }
        let code = command(.loadfile, args: [url.isFileURL ? url.path : url.absoluteString, "replace"])
        if code < 0 {
            delegate?.finish(player: self, error: playbackError(code, stage: "loadfile"))
        }
    }

    public func shutdown() {
        completeSeek(false)
        destroyHandle()
        hasRequestedLoad = false
        backgroundVideoID = nil
        reachedEnd = false
        tracks = []
        duration = 0
        currentPlaybackTime = 0
        isReadyToPlay = false
        playbackState = .stopped
        loadState = .idle
    }

    public func reset() { shutdown() }

    public func seek(time: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard isReadyToPlay, seekable, time.isFinite else { completion(false); return }
        completeSeek(false)
        reachedEnd = false
        seekCompletion = completion
        let target = min(duration, max(0, time))
        // Pause is independent of seeking; don't overwrite the transport state.
        let code = command(.seek, args: [String(target), "absolute+exact"])
        guard code >= 0 else { completeSeek(false); return }
        seekTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.diagnostic("seek 超时")
            self?.completeSeek(false)
        }
    }

    private func completeSeek(_ finished: Bool) {
        seekTimeout?.cancel()
        seekTimeout = nil
        let callback = seekCompletion
        seekCompletion = nil
        if finished { currentPlaybackTime = getDouble("time-pos") }
        callback?(finished)
    }

    private func playbackError(_ code: Int32, stage: String) -> NSError {
        let reason = String(cString: mpv_error_string(code))
        let details = initializationError ?? recentErrors.last ?? reason
        diagnostic("\(stage) 失败：code=\(code)，\(details)")
        return NSError(domain: "KSMPVPlayer", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "KSMPVPlayer：\(details)（\(code)）"
        ])
    }

    public func configPIP() {}
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
        seek(time: seekTime) { _ in }
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
            if !newValue {
                if mediaType == .subtitle { handle?.setString(MPVOption.TrackSelection.sid, "no") }
                return
            }
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
