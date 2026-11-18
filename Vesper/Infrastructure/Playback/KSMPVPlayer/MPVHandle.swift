//
//  MPVHandle.swift
//
//
//  Created by kintan on 5/2/24.
//

import Foundation
@preconcurrency import KSPlayer
import libmpv
import QuartzCore
import GLKit
import OpenGLES
import Darwin
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@MainActor
public class MPVHandle: NSObject, @unchecked Sendable {
    private(set) var initializationStatus: Int32 = 0
    private(set) var initializationError: String?
    var mpv: OpaquePointer?
    let renderView: KSMPVRenderView?
    private let fallbackView = UIView()
    var videoView: UIView { renderView ?? fallbackView }
    private var displayLink: CADisplayLink?
    private var eventTimer: Timer?
    private var displayTarget: KSMPVDisplayTarget?
    private(set) var recentErrors: [String] = []

    public init(options: KSOptions) {
        if let context = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2) {
            renderView = KSMPVRenderView(context: context)
        } else {
            renderView = nil
        }
        super.init()
        fallbackView.backgroundColor = .black
        initializeHandle(options: options)
    }

    func initializeHandle(options: KSOptions) {
        guard mpv == nil else { return }
        initializationStatus = 0
        initializationError = nil
        recentErrors = []
        guard let renderView else {
            initializationStatus = -18
            initializationError = "OpenGL ES 不可用"
            return
        }
        guard let handle = mpv_create() else {
            initializationStatus = -2
            initializationError = "无法创建 libmpv 实例"
            return
        }
        mpv = handle
        // FFmpegKit 6.1.4 bundles mpv 0.37 with ios-gl, not the newer
        // gpu-next/MoltenVK CAMetalLayer window backend. KSMPVPlayer keeps
        // upstream playback/track handling and uses its public render API here.
        let settings: [(String, String)] = [
            ("config", "no"), ("terminal", "no"), ("vo", "libmpv"),
            ("hwdec", options.hardwareDecode ? "auto-safe" : "no"),
            ("ao", "audiounit"), ("idle", "yes"), ("pause", "yes"),
            ("keep-open", "yes"), ("volume-max", "100"), ("sid", "no"),
            ("input-default-bindings", "no"), ("input-vo-keyboard", "no"),
            ("cache-secs", String(max(1, Int(options.maxBufferDuration)))),
            ("cache-pause-wait", String(max(1, Int(options.preferredForwardBufferDuration)))),
            ("speed", String(options.startPlayRate))
        ]
        for (name, value) in settings {
            let status = mpv_set_option_string(handle, name, value)
            if status < 0 {
                check(status: status, operation: "option \(name)=\(value)")
                if name == "vo" || name == "ao" {
                    initializationStatus = status
                    initializationError = "\(name): \(String(cString: mpv_error_string(status)))"
                    return
                }
            }
        }
        mpv_request_log_messages(handle, "warn")
        for (name, format) in observeProperties {
            check(status: mpv_observe_property(handle, 0, name, format), operation: "observe \(name)")
        }
        initializationStatus = mpv_initialize(handle)
        guard initializationStatus >= 0 else {
            initializationError = String(cString: mpv_error_string(initializationStatus))
            check(status: initializationStatus, operation: "initialize")
            return
        }
        initializationStatus = renderView.attach(handle)
        guard initializationStatus >= 0 else {
            initializationError = "libmpv OpenGL 渲染初始化失败：\(String(cString: mpv_error_string(initializationStatus)))"
            check(status: initializationStatus, operation: "render context create")
            return
        }
        let target = KSMPVDisplayTarget(owner: self)
        displayTarget = target
        let link = CADisplayLink(target: target, selector: #selector(KSMPVDisplayTarget.tick))
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        displayLink = link
        // Keep processing EOF/errors/audio state even when display refresh stops
        // in the background. No C callback retains or dereferences a dead owner.
        eventTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.readEvents() }
        }
        diagnostic("已初始化 KSMPVPlayer，libmpv=\(getString("mpv-version") ?? "unknown")，renderer=libmpv/OpenGL ES，hardware=\(options.hardwareDecode)")
    }

    fileprivate func tick() {
        readEvents()
        renderView?.drawPendingFrame()
    }

    private func readEvents() {
        while let mpv, let event = mpv_wait_event(mpv, 0) {
            if event.pointee.event_id == MPV_EVENT_NONE { break }
            handle(event: event.pointee)
        }
    }

    func setRenderingInBackground(_ background: Bool) {
        displayLink?.isPaused = background
        if !background { renderView?.setNeedsDisplay() }
    }

    func destroyHandle() {
        eventTimer?.invalidate()
        eventTimer = nil
        displayLink?.invalidate()
        displayLink = nil
        displayTarget = nil
        // Render context must be freed with its EAGLContext current, BEFORE mpv.
        renderView?.detach()
        guard let handle = mpv else { return }
        mpv = nil
        mpv_terminate_destroy(handle)
    }

    func diagnostic(_ message: String) {
        AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [KSMPVPlayer] \(message)")
    }

    open func handle(event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_SHUTDOWN:
            destroyHandle()
        case MPV_EVENT_PROPERTY_CHANGE:
            let dataOpaquePtr = OpaquePointer(event.data)
            if let property = UnsafePointer<mpv_event_property>(dataOpaquePtr)?.pointee {
                let propertyName = String(cString: property.name)
                change(property: property, name: propertyName)
            }
        case MPV_EVENT_LOG_MESSAGE:
            if let data = event.data {
                let msg = data.load(as: mpv_event_log_message.self)
                let message = "[\(String(cString: msg.prefix))] \(String(cString: msg.text).trimmingCharacters(in: .whitespacesAndNewlines))"
                if msg.log_level <= MPV_LOG_LEVEL_ERROR.rawValue {
                    recentErrors.append(message)
                    recentErrors = Array(recentErrors.suffix(6))
                }
                diagnostic(message)
            }
        default:
            if let eventName = mpv_event_name(event.event_id) {
                KSLog("eventID \(event.event_id.rawValue) name=\(String(cString: eventName))")
            }
        }
    }

    open func change(property _: mpv_event_property, name _: String) {}
#if DEBUG
    deinit {
        KSLog("")
    }
#endif

    private let observeProperties: [String: mpv_format] = [
        "time-pos": MPV_FORMAT_DOUBLE,
        "duration": MPV_FORMAT_DOUBLE,
        "eof-reached": MPV_FORMAT_FLAG,
        "pause": MPV_FORMAT_FLAG,
        "paused-for-cache": MPV_FORMAT_FLAG
    ]
}

extension MPVHandle {
    // MARK: - Command & property

    private func makeCArgs(_ command: MPVCommand, _ args: [String?]) -> [String?] {
        if args.count > 0, args.last == nil {
            KSLog("Command do not need a nil suffix")
        }
        var strArgs = args
        strArgs.insert(command.rawValue, at: 0)
        strArgs.append(nil)
        return strArgs
    }

    /// Send arbitrary mpv command.
    func command(_ command: MPVCommand, args: [String?] = [], checkError: Bool = true) -> Int32 {
        guard let mpv else { return -3 }
        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for ptr in cargs {
                if ptr != nil {
                    free(UnsafeMutablePointer(mutating: ptr!))
                }
            }
        }
        let returnValue = mpv_command(mpv, &cargs)
        if checkError {
            check(status: returnValue, operation: "command \(command.rawValue)")
        }
        return returnValue
    }

    func command(rawString: String) -> Int32 {
        mpv_command_string(mpv, rawString)
    }

    func asyncCommand(_ command: MPVCommand, args: [String?] = [], checkError: Bool = true, replyUserdata: UInt64) {
        guard let mpv else { return }
        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for ptr in cargs {
                if ptr != nil {
                    free(UnsafeMutablePointer(mutating: ptr!))
                }
            }
        }
        let returnValue = mpv_command_async(mpv, replyUserdata, &cargs)
        if checkError {
            check(status: returnValue, operation: "command \(command.rawValue)")
        }
    }

    func observe(property: String, format: mpv_format = MPV_FORMAT_DOUBLE) {
        mpv_observe_property(mpv, 0, property, format)
    }

    /// Set property
    func setFlag(_ name: String, _ flag: Bool) {
        guard let mpv else { return }
        var data: Int32 = flag ? 1 : 0
        check(status: mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data), operation: "set \(name)")
    }

    func setInt(_ name: String, _ value: Int) {
        guard let mpv else { return }
        var data = Int64(value)
        check(status: mpv_set_property(mpv, name, MPV_FORMAT_INT64, &data), operation: "set \(name)")
    }

    func setDouble(_ name: String, _ value: Double) {
        guard let mpv else { return }
        var data = value
        check(status: mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data), operation: "set \(name)")
    }

    func setFlagAsync(_ name: String, _ flag: Bool) {
        guard let mpv else { return }
        var data: Int32 = flag ? 1 : 0
        mpv_set_property_async(mpv, 0, name, MPV_FORMAT_FLAG, &data)
    }

    func setIntAsync(_ name: String, _ value: Int) {
        guard let mpv else { return }
        var data = Int64(value)
        mpv_set_property_async(mpv, 0, name, MPV_FORMAT_INT64, &data)
    }

    func setDoubleAsync(_ name: String, _ value: Double) {
        guard let mpv else { return }
        var data = value
        mpv_set_property_async(mpv, 0, name, MPV_FORMAT_DOUBLE, &data)
    }

    func setString(_ name: String, _ value: String) {
        guard let mpv else { return }
        check(status: mpv_set_property_string(mpv, name, value), operation: "set \(name)")
    }

    func getInt(_ name: String) -> Int {
        guard let mpv else { return 0 }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
        return Int(data)
    }

    func getDouble(_ name: String) -> Double {
        guard let mpv else { return 0.0 }
        var data = Double()
        mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
        return data
    }

    func getFlag(_ name: String) -> Bool {
        guard let mpv else { return false }
        var data = Int32()
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }

    func getString(_ name: String) -> String? {
        guard let mpv else { return nil }
        let cstr = mpv_get_property_string(mpv, name)
        let str: String? = cstr == nil ? nil : String(cString: cstr!)
        mpv_free(cstr)
        return str
    }

    func setOption(name: String, value: String) {
        guard let mpv else { return }
        check(status: mpv_set_option_string(mpv, name, value), operation: "option \(name)")
    }

    func check(status: CInt, operation: String = "API") {
        if status < 0 { diagnostic("\(operation)：\(status) \(String(cString: mpv_error_string(status)))") }
    }
}

@MainActor
private final class KSMPVDisplayTarget: NSObject {
    weak var owner: MPVHandle?
    init(owner: MPVHandle) { self.owner = owner }
    @objc func tick() { owner?.tick() }
}

/// libmpv's public render API owns the video and libass subtitle composition.
/// GL objects are created, used and released with the same EAGLContext current.
@MainActor
final class KSMPVRenderView: GLKView, @preconcurrency GLKViewDelegate {
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
    func attach(_ handle: OpaquePointer) -> Int32 {
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
            return params.withUnsafeMutableBufferPointer { mpv_render_context_create(&renderContext, handle, $0.baseAddress) }
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

@MainActor
func runOnMainThread(_ action: () -> Void) { action() }
