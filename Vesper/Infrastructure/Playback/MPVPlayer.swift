import AVFoundation
import AVKit
import GLKit
import OpenGLES
import Darwin
@preconcurrency import KSPlayer
import libmpv

/// Adapts libmpv to the same KSPlayer session used by Vesper's controls.
/// All C calls, event consumption, and GL rendering are serialized on MainActor.
@MainActor
final class VesperMPVPlayer: NSObject, @preconcurrency MediaPlayerProtocol {
    weak var delegate: MediaPlayerDelegate?
    private var handle: OpaquePointer?
    private let surface: MPVRenderView?
    private let fallbackSurface = UIView()
    private var eventTimer: Timer?
    private var displayLink: CADisplayLink?
    private var url: URL
    private var options: KSOptions
    private var seekCompletion: ((Bool) -> Void)?
    private var seekDeadline = Date.distantPast
    private var backgroundVideoID: String?
    private var loaded = false
    private var failed = false
    private var reachedEnd = false
    private var mediaTracks: [MPVMediaTrack] = []
    private let coordinatorPlayer = AVPlayer()

    private(set) var duration: TimeInterval = 0
    private(set) var fileSize: Double = 0
    private(set) var naturalSize: CGSize = .zero
    var chapters: [Chapter] { [] }
    private(set) var currentPlaybackTime: TimeInterval = 0
    private(set) var playableTime: TimeInterval = 0
    private(set) var isReadyToPlay = false
    private(set) var playbackState: MediaPlaybackState = .idle
    private(set) var loadState: MediaLoadState = .idle
    var view: UIView? { surface ?? fallbackSurface }
    var isPlaying: Bool { playbackState == .playing }
    var seekable: Bool { loaded && flag("seekable") }
    var subtitleDataSouce: SubtitleDataSouce? { nil } // mpv/libass renders subtitles into the video.
    var pipController: KSPictureInPictureController? { nil }
    var playbackCoordinator: AVPlaybackCoordinator { coordinatorPlayer.playbackCoordinator }
    var dynamicInfo: DynamicInfo? { nil }
    var allowsExternalPlayback = false
    var usesExternalPlaybackWhileExternalScreenIsActive = false
    var isExternalPlaybackActive: Bool { false }
    var isMuted = false { didSet { set("mute", isMuted ? "yes" : "no") } }
    var playbackRate: Float = 1 { didSet { set("speed", String(playbackRate)) } }
    var playbackVolume: Float = 1 { didSet { set("volume", String(min(1, max(0, playbackVolume)) * 100)) } }
    var contentMode: UIView.ContentMode = .scaleAspectFit {
        didSet { set("panscan", contentMode == .scaleAspectFill ? "1" : "0") }
    }

    required init(url: URL, options: KSOptions) {
        self.url = url
        self.options = options
        if let context = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2) {
            surface = MPVRenderView(context: context)
        } else {
            surface = nil
            fallbackSurface.backgroundColor = .black
        }
        super.init()
    }

    func replace(url: URL, options: KSOptions) {
        shutdown()
        self.url = url
        self.options = options
    }

    func prepareToPlay() {
        guard handle == nil else { return }
        failed = false
        guard let surface else { fail("OpenGL ES 不可用，无法启动 mpv 渲染"); return }
        guard let context = mpv_create() else { fail("无法创建 mpv 播放器"); return }
        handle = context
        let initialOptions = [
            "video-timing-offset": "0", "vo": "libmpv", "hwdec": options.hardwareDecode ? "auto-safe" : "no",
            "ao": "audiounit", "idle": "yes", "keep-open": "yes", "pause": "yes",
            "config": "no", "input-default-bindings": "no", "input-vo-keyboard": "no",
            "terminal": "no", "osc": "no", "sub-auto": "no", "volume-max": "100",
            "speed": String(options.startPlayRate)
        ]
        for (name, value) in initialOptions {
            let result = mpv_set_option_string(context, name, value)
            if result < 0 { log("option \(name): \(errorString(result))") }
        }
        let result = mpv_initialize(context)
        guard result >= 0 else { fail("mpv initialize: \(errorString(result))"); return }
        guard surface.attach(context) else { fail("mpv OpenGL 渲染初始化失败"); return }
        mpv_request_log_messages(context, "warn")
        loadState = .loading
        delegate?.changeLoadState(player: self)
        let proxy = MPVDisplayLinkTarget(player: self)
        let link = CADisplayLink(target: proxy, selector: #selector(MPVDisplayLinkTarget.tick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
        eventTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        command(["loadfile", url.isFileURL ? url.path : url.absoluteString, "replace"])
        log("初始化：hwdec=\(options.hardwareDecode) urlScheme=\(url.scheme ?? "none")")
    }

    func play() {
        if handle == nil { prepareToPlay() }
        set("pause", "no")
        playbackState = .playing
    }
    func pause() { set("pause", "yes"); playbackState = .paused }
    func shutdown() {
        eventTimer?.invalidate()
        eventTimer = nil
        displayLink?.invalidate()
        displayLink = nil
        surface?.detach()
        if let handle { mpv_terminate_destroy(handle) }
        handle = nil
        loaded = false
        reachedEnd = false
        isReadyToPlay = false
        loadState = .idle
        playbackState = .stopped
        let completion = seekCompletion
        seekCompletion = nil
        completion?(false)
        mediaTracks = []
        backgroundVideoID = nil
    }
    func seek(time: TimeInterval, completion: @escaping ((Bool) -> Void)) {
        guard loaded, time.isFinite else { completion(false); return }
        let previous = seekCompletion
        seekCompletion = nil
        previous?(false)
        seekCompletion = completion
        seekDeadline = Date().addingTimeInterval(10)
        playbackState = .seeking
        command(["seek", String(max(0, time)), "absolute+exact"])
    }
    func enterBackground() {
        displayLink?.isPaused = true
        if loaded && backgroundVideoID == nil {
            backgroundVideoID = string("vid")
            set("vid", "no") // Keep audio running without making GL calls in the background.
        }
    }
    func enterForeground() {
        if let videoID = backgroundVideoID {
            backgroundVideoID = nil
            set("vid", videoID)
        }
        displayLink?.isPaused = false
        surface?.setNeedsDisplay()
    }
    func thumbnailImageAtCurrentTime() async -> CGImage? {
        guard loaded, UIApplication.shared.applicationState != .background,
              let surface, surface.window != nil else { return nil }
        return surface.snapshot.cgImage
    }
    func tracks(mediaType: AVMediaType) -> [any MediaPlayerTrack] { mediaTracks.filter { $0.mediaType == mediaType } }
    func select(track: some MediaPlayerTrack) {
        set(track.mediaType == .audio ? "aid" : "sid", String(track.trackID))
        refreshTracks()
    }
    func disableSubtitles() { set("sid", "no"); refreshTracks() }
    var usingHardwareDecoder: Bool { let value = string("hwdec-current"); return !value.isEmpty && value != "no" }

    fileprivate func tick() {
        guard let handle, !failed else { return }
        // Limit one turn's work so a burst of log/property events cannot starve UI.
        for _ in 0..<100 {
            guard let event = mpv_wait_event(handle, 0)?.pointee, event.event_id != MPV_EVENT_NONE else { break }
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED:
                loaded = true
                isReadyToPlay = true
                duration = number("duration")
                fileSize = number("file-size")
                naturalSize = CGSize(width: number("video-params/dw"), height: number("video-params/dh"))
                refreshTracks()
                // Match KSPlayer's default: subtitles start disabled.
                set("sid", "no")
                set("mute", isMuted ? "yes" : "no")
                loadState = .playable
                delegate?.readyToPlay(player: self)
                delegate?.changeLoadState(player: self)
                log("已加载：duration=\(duration) hwdec=\(string("hwdec-current")) tracks=\(mediaTracks.count)")
            case MPV_EVENT_PLAYBACK_RESTART:
                playbackState = flag("pause") ? .paused : .playing
                let completion = seekCompletion
                seekCompletion = nil
                completion?(true)
            case MPV_EVENT_END_FILE:
                if let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee,
                   data.reason == MPV_END_FILE_REASON_ERROR { fail("mpv: \(errorString(data.error))") }
                else if let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee,
                        data.reason == MPV_END_FILE_REASON_EOF { finishPlayback() }
            case MPV_EVENT_LOG_MESSAGE:
                if let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                   let text = message.text { log(String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)) }
            default: break
            }
        }
        guard !failed else { return }
        if loaded {
            currentPlaybackTime = number("time-pos")
            duration = number("duration")
            playableTime = currentPlaybackTime + number("demuxer-cache-duration")
            let next: MediaLoadState = flag("paused-for-cache") ? .loading : .playable
            if loadState != next { loadState = next; delegate?.changeLoadState(player: self) }
            if flag("eof-reached") {
                finishPlayback()
            } else {
                reachedEnd = false
                if seekCompletion == nil { playbackState = flag("pause") ? .paused : .playing }
            }
            if seekCompletion != nil && Date() > seekDeadline {
                let completion = seekCompletion
                seekCompletion = nil
                completion?(false)
            }
        }
        surface?.drawPendingFrame()
    }

    private func finishPlayback() {
        guard !reachedEnd else { return }
        reachedEnd = true
        playbackState = .finished
        delegate?.finish(player: self, error: nil)
    }

    private func refreshTracks() {
        mediaTracks = (0..<Int(number("track-list/count"))).compactMap { index in
            let prefix = "track-list/\(index)/"
            let type = string(prefix + "type")
            guard type == "audio" || type == "sub" else { return nil }
            let id = Int32(number(prefix + "id"))
            let language = string(prefix + "lang")
            let title = string(prefix + "title")
            let track = MPVMediaTrack(id: id, name: title.isEmpty ? "\(language.isEmpty ? type : language) \(id)" : title,
                                      language: language, type: type == "audio" ? .audio : .subtitle,
                                      enabled: flag(prefix + "selected"))
            track.selectionChanged = { [weak self] enabled in
                self?.set(type == "audio" ? "aid" : "sid", enabled ? String(id) : "no")
            }
            return track
        }
    }
    private func command(_ arguments: [String]) {
        guard let handle else { return }
        let strings = arguments.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var argv: [UnsafePointer<CChar>?] = strings.map { pointer in pointer.map { UnsafePointer<CChar>($0) } } + [nil]
        let result = argv.withUnsafeMutableBufferPointer { mpv_command(handle, $0.baseAddress) }
        if result < 0 { fail("mpv command \(arguments.first ?? ""): \(errorString(result))") }
    }
    private func set(_ name: String, _ value: String) {
        guard let handle else { return }
        let result = mpv_set_property_string(handle, name, value)
        if result < 0 { log("property \(name): \(errorString(result))") }
    }
    private func number(_ name: String) -> Double {
        guard let handle else { return 0 }
        var result: Double = 0
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &result) >= 0, result.isFinite else { return 0 }
        return result
    }
    private func flag(_ name: String) -> Bool {
        guard let handle else { return false }
        var result: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &result) >= 0 && result != 0
    }
    private func string(_ name: String) -> String {
        guard let handle, let value = mpv_get_property_string(handle, name) else { return "" }
        defer { mpv_free(value) }
        return String(cString: value)
    }
    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        log(message)
        delegate?.finish(player: self, error: NSError(domain: "Vesper.MPV", code: -1, userInfo: [NSLocalizedDescriptionKey: message]))
    }
    private func log(_ message: String) {
        AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [MPV] \(message)")
    }
    private func errorString(_ code: Int32) -> String { String(cString: mpv_error_string(code)) }
}

@MainActor
private final class MPVDisplayLinkTarget: NSObject {
    weak var player: VesperMPVPlayer?
    init(player: VesperMPVPlayer) { self.player = player }
    @objc func tick() { player?.tick() }
}

@MainActor
private final class MPVMediaTrack: @preconcurrency MediaPlayerTrack {
    let trackID: Int32
    let name: String
    let languageCode: String?
    let mediaType: AVMediaType
    var nominalFrameRate: Float = 0
    var bitRate: Int64 { 0 }
    var bitDepth: Int32 { 0 }
    var isEnabled: Bool { didSet { selectionChanged?(isEnabled) } }
    var isImageSubtitle: Bool { false }
    var rotation: Int16 { 0 }
    var dovi: DOVIDecoderConfigurationRecord? { nil }
    var fieldOrder: FFmpegFieldOrder { .progressive }
    var formatDescription: CMFormatDescription? { nil }
    var description: String { name }
    var selectionChanged: ((Bool) -> Void)?
    init(id: Int32, name: String, language: String, type: AVMediaType, enabled: Bool) {
        trackID = id; self.name = name; languageCode = language.isEmpty ? nil : language
        mediaType = type; isEnabled = enabled
    }
}

/// libmpv's public render API owns the video and libass subtitle composition.
/// GL objects are created, used and released with the same EAGLContext current.
@MainActor
private final class MPVRenderView: GLKView, @preconcurrency GLKViewDelegate {
    private var renderContext: OpaquePointer?
    init(context: EAGLContext) {
        // OpenGL ES is the render API provided by this pinned libmpv build.
        super.init(frame: .zero, context: context)
        delegate = self
        enableSetNeedsDisplay = true
        drawableDepthFormat = .formatNone
        drawableColorFormat = .RGBA8888
        contentScaleFactor = traitCollection.displayScale
        backgroundColor = .black
        isOpaque = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func attach(_ handle: OpaquePointer) -> Bool {
        EAGLContext.setCurrent(context)
        var gl = mpv_opengl_init_params(get_proc_address: { _, name in
            guard let name else { return nil }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
        }, get_proc_address_ctx: nil)
        let api = strdup("opengl")!
        defer { free(api) }
        return withUnsafeMutablePointer(to: &gl) { glPointer in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(glPointer)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]
            return params.withUnsafeMutableBufferPointer { mpv_render_context_create(&renderContext, handle, $0.baseAddress) >= 0 }
        }
    }
    func detach() {
        EAGLContext.setCurrent(context)
        if let renderContext { mpv_render_context_free(renderContext) }
        renderContext = nil
    }
    func drawPendingFrame() {
        guard let renderContext, window != nil, bounds.width > 0, bounds.height > 0,
              UIApplication.shared.applicationState != .background else { return }
        EAGLContext.setCurrent(context)
        if mpv_render_context_update(renderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 { display() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard renderContext != nil, UIApplication.shared.applicationState != .background else { return }
        display()
    }
    func glkView(_ view: GLKView, drawIn rect: CGRect) {
        guard let renderContext, UIApplication.shared.applicationState != .background else { return }
        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &framebuffer)
        var fbo = mpv_opengl_fbo(fbo: framebuffer, w: Int32(drawableWidth), h: Int32(drawableHeight), internal_format: 0)
        var flip: Int32 = 1
        var block: Int32 = 0
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                withUnsafeMutablePointer(to: &block) { blockPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    params.withUnsafeMutableBufferPointer { mpv_render_context_render(renderContext, $0.baseAddress) }
                }
            }
        }
        mpv_render_context_report_swap(renderContext)
    }
}
