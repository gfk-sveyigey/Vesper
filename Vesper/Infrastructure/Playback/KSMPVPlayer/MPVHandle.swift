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
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@MainActor
public class MPVHandle: NSObject, @unchecked Sendable {
    private(set) var initializationStatus: Int32 = 0
    var mpv: OpaquePointer?
    let metalView: MetalView
    @MainActor
    public init(options: KSOptions) {
        metalView = MetalView()
        super.init()
        initializeHandle(options: options)
    }

    func initializeHandle(options: KSOptions) {
        guard mpv == nil else { return }
        mpv = mpv_create()
        guard mpv != nil else { initializationStatus = -1; return }
        #if DEBUG
        check(status: mpv_request_log_messages(mpv, "debug"))
        #else
        check(status: mpv_request_log_messages(mpv, "no"))
        #endif
        setOption(name: MPVOption.Input.inputMediaKeys, value: "yes")
        var layer = Int64(Int(bitPattern: Unmanaged.passUnretained(metalView.layer).toOpaque()))
        check(status: mpv_set_option(mpv, MPVOption.Window.wid, MPV_FORMAT_INT64, &layer))
        setOption(name: "subs-match-os-language", value: "yes")
//        setOption(name: "subs-fallback", value: "yes")
//        setOption(name: MPVOption.Subtitles.subAssOverride, value: "no")
//        setOption(name: MPVOption.GPURendererOptions.targetColorspaceHint, value: "yes")
        setOption(name: MPVOption.Video.vo, value: "gpu-next")
        setOption(name: MPVOption.GPURendererOptions.gpuApi, value: "vulkan")
        setOption(name: MPVOption.GPURendererOptions.gpuContext, value: "moltenvk")
        setOption(name: MPVOption.Video.hwdec, value: options.hardwareDecode ? "videotoolbox" : "no")
        setOption(name: "idle", value: "yes")
        setOption(name: "pause", value: "yes")
        setOption(name: "keep-open", value: "yes")
        setOption(name: "volume-max", value: "100")
        setOption(name: MPVOption.Audio.ao, value: "audiounit")
        setOption(name: MPVOption.Cache.cacheSecs, value: String(Int(options.maxBufferDuration)))
        setOption(name: MPVOption.Cache.cachePauseWait, value: String(Int(options.preferredForwardBufferDuration)))
        setOption(name: MPVOption.Cache.cachePauseInitial, value: "yes")
        for (k, v) in observeProperties {
            mpv_observe_property(mpv, 0, k, v)
        }
        initializationStatus = mpv_initialize(mpv)
        check(status: initializationStatus)
        mpv_set_wakeup_callback(mpv, { ctx in
            guard let ctx else { return }
            let owner = Unmanaged<MPVHandle>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor [weak owner] in owner?.readEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func readEvents() {
        while let mpv, let event = mpv_wait_event(mpv, 0) {
            if event.pointee.event_id == MPV_EVENT_NONE { break }
            handle(event: event.pointee)
        }
    }

    func destroyHandle() {
        guard let handle = mpv else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        mpv = nil
        mpv_terminate_destroy(handle)
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
            if let msg = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(event.data)) {
                KSLog("[\(String(cString: (msg.pointee.prefix)!))] \(String(cString: (msg.pointee.level)!))=\(String(cString: (msg.pointee.text)!))")
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
        MPVProperty.trackList: MPV_FORMAT_NONE,
        MPVProperty.vf: MPV_FORMAT_NONE,
        MPVProperty.af: MPV_FORMAT_NONE,
        MPVProperty.timePos: MPV_FORMAT_DOUBLE,
        "eof-reached": MPV_FORMAT_FLAG,
        MPVOption.TrackSelection.vid: MPV_FORMAT_INT64,
        MPVOption.TrackSelection.aid: MPV_FORMAT_INT64,
        MPVOption.TrackSelection.sid: MPV_FORMAT_INT64,
        MPVOption.Subtitles.secondarySid: MPV_FORMAT_INT64,
        MPVOption.PlaybackControl.pause: MPV_FORMAT_FLAG,
        MPVOption.PlaybackControl.loopPlaylist: MPV_FORMAT_STRING,
        MPVOption.PlaybackControl.loopFile: MPV_FORMAT_STRING,
        MPVProperty.chapter: MPV_FORMAT_INT64,
        MPVOption.Video.deinterlace: MPV_FORMAT_FLAG,
        MPVOption.Video.hwdec: MPV_FORMAT_STRING,
        MPVOption.Video.videoRotate: MPV_FORMAT_INT64,
        MPVOption.Audio.mute: MPV_FORMAT_FLAG,
        MPVOption.Audio.volume: MPV_FORMAT_DOUBLE,
        MPVOption.Audio.audioDelay: MPV_FORMAT_DOUBLE,
        MPVOption.PlaybackControl.speed: MPV_FORMAT_DOUBLE,
        MPVOption.Subtitles.subDelay: MPV_FORMAT_DOUBLE,
        MPVOption.Subtitles.subScale: MPV_FORMAT_DOUBLE,
        MPVOption.Subtitles.subPos: MPV_FORMAT_DOUBLE,
        MPVOption.Equalizer.contrast: MPV_FORMAT_INT64,
        MPVOption.Equalizer.brightness: MPV_FORMAT_INT64,
        MPVOption.Equalizer.gamma: MPV_FORMAT_INT64,
        MPVOption.Equalizer.hue: MPV_FORMAT_INT64,
        MPVOption.Equalizer.saturation: MPV_FORMAT_INT64,
        MPVOption.Window.fullscreen: MPV_FORMAT_FLAG,
        MPVOption.Window.ontop: MPV_FORMAT_FLAG,
        MPVOption.Window.windowScale: MPV_FORMAT_DOUBLE,
        MPVProperty.mediaTitle: MPV_FORMAT_STRING,
        MPVProperty.videoParamsRotate: MPV_FORMAT_INT64,
        MPVProperty.videoParamsPrimaries: MPV_FORMAT_STRING,
        MPVProperty.videoParamsGamma: MPV_FORMAT_STRING,
        MPVProperty.idleActive: MPV_FORMAT_FLAG,
        MPVProperty.pausedForCache: MPV_FORMAT_FLAG,
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
        guard let mpv else { return 0 }
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
            check(status: returnValue)
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
            check(status: returnValue)
        }
    }

    func observe(property: String, format: mpv_format = MPV_FORMAT_DOUBLE) {
        mpv_observe_property(mpv, 0, property, format)
    }

    /// Set property
    func setFlag(_ name: String, _ flag: Bool) {
        guard let mpv else { return }
        var data: Int32 = flag ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }

    func setInt(_ name: String, _ value: Int) {
        guard let mpv else { return }
        var data = Int64(value)
        mpv_set_property(mpv, name, MPV_FORMAT_INT64, &data)
    }

    func setDouble(_ name: String, _ value: Double) {
        guard let mpv else { return }
        var data = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
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
        mpv_set_property_string(mpv, name, value)
    }

    func getInt(_ name: String) -> Int {
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
        let cstr = mpv_get_property_string(mpv, name)
        let str: String? = cstr == nil ? nil : String(cString: cstr!)
        mpv_free(cstr)
        return str
    }

    func setOption(name: String, value: String) {
        guard let mpv else { return }
        check(status: mpv_set_option_string(mpv, name, value))
    }

    func check(status: CInt) {
        if status < 0 {
            AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [KSMPVPlayer] error=\(status) \(String(cString: mpv_error_string(status)))")
            KSLog("MPV API error=\(String(cString: mpv_error_string(status))), Return value=\(status).")
        }
    }
}

// KSPlayer 2.3.4's MetalView is internal; provide the same CAMetalLayer host.
@MainActor
final class MetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
}

@MainActor
func runOnMainThread(_ action: () -> Void) { action() }
