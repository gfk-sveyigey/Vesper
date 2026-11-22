import AVFoundation
import AVKit
import Combine
import MediaPlayer
import SwiftUI
import UIKit

/// The app remains portrait-only until its full-screen player is presented.
@MainActor
enum PlayerOrientationPolicy {
    static var allowsLandscape = false
    static var isLandscape: Bool {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }?.effectiveGeometry.interfaceOrientation.isLandscape == true
    }

    static func update(_ enabled: Bool, scene: UIWindowScene? = nil) {
        allowsLandscape = enabled
        guard let scene = scene ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.windows.forEach { window in
            if let controller = window.rootViewController { refresh(controller) }
        }
        if !enabled { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
    }
    private static func refresh(_ controller: UIViewController) {
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        controller.children.forEach(refresh)
        if let presented = controller.presentedViewController { refresh(presented) }
    }
}

@MainActor
final class VesperAppDelegate: NSObject, UIApplicationDelegate {
    // Keep SwiftUI in charge of scene/window creation; forward document events
    // through the delegate that the app actually registers.
    private let fileDelivery = VesperFileDeliveryDelegate()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        fileDelivery.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func application(_ application: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        fileDelivery.application(application, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void) -> Bool {
        fileDelivery.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        fileDelivery.application(application, configurationForConnecting: connectingSceneSession, options: options)
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        PlayerOrientationPolicy.allowsLandscape ? .allButUpsideDown : .portrait
    }
}

enum PlayerGestureRegion: String, CaseIterable, Identifiable {
    case left, center, right
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self { case .left: "左侧区域"; case .center: "中间区域"; case .right: "右侧区域" }
    }
    static func at(_ point: CGPoint, width: CGFloat, count: Int) -> Self {
        let edges = PlayerGesturePreferences.boundaries(for: count)
        let x = point.x / max(width, 1)
        if edges.isEmpty { return .center }
        if x < edges[0] { return .left }
        if edges.count == 1 { return .right }
        return x < edges[1] ? .center : .right
    }
}

enum PlayerGestureKind: String, CaseIterable, Identifiable {
    case tap, doubleTap, longPress, up, down, left, right, pinchIn, pinchOut
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .longPress: "长按"; case .tap: "单击"; case .doubleTap: "双击"; case .up: "向上滑动"; case .down: "向下滑动"
        case .left: "向左滑动"; case .right: "向右滑动"; case .pinchIn: "捏合"; case .pinchOut: "张开"
        }
    }
    var needsTwoFingers: Bool { [.pinchIn, .pinchOut].contains(self) }
}

enum PlayerGestureAction: String, CaseIterable, Identifiable {
    case none, controls, playback, play, pause, backward, forward, brightnessUp, brightnessDown, volumeUp, volumeDown
    case mute, showRegions, playlist, synopsis, details, debugInfo, rotate, fill, fillScreen, fitScreen, landscape, portrait, pictureInPicture, close, speedUp, speedDown, moreSettings, subtitles, danmaku, gestures
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .none: "无操作"; case .controls: "显隐控制层"; case .playback: "暂停或继续播放"
        case .play: "播放"; case .pause: "暂停"; case .backward: "快退"; case .forward: "快进"
        case .brightnessUp: "增大亮度"; case .brightnessDown: "减小亮度"; case .volumeUp: "增大音量"; case .volumeDown: "减小音量"
        case .mute: "静音或取消静音"; case .showRegions: "显示区域划分"; case .playlist: "播放列表"
        case .synopsis: "视频简介"; case .details: "详细信息"; case .debugInfo: "显隐调试信息"; case .rotate: "切换屏幕方向"; case .fill: "切换填充方式"
        case .fillScreen: "填满屏幕"; case .fitScreen: "完整显示"; case .landscape: "横屏"; case .portrait: "竖屏"
        case .pictureInPicture: "画中画"; case .close: "退出播放"; case .speedUp: "加快播放速度"; case .speedDown: "减慢播放速度"
        case .moreSettings: "更多设置"; case .subtitles: "字幕设置"; case .danmaku: "弹幕设置"; case .gestures: "播放手势"
        }
    }
    static func choices(for kind: PlayerGestureKind) -> [Self] { allCases }
}

enum PlayerGesturePair: String, CaseIterable, Identifiable {
    case vertical, horizontal, pinch
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self { case .vertical: "上下滑动"; case .horizontal: "左右滑动"; case .pinch: "张开／捏合" }
    }
    var positive: PlayerGestureKind {
        switch self { case .vertical: .up; case .horizontal: .right; case .pinch: .pinchOut }
    }
    var negative: PlayerGestureKind {
        switch self { case .vertical: .down; case .horizontal: .left; case .pinch: .pinchIn }
    }
    var needsTwoFingers: Bool { self == .pinch }
    static func containing(_ kind: PlayerGestureKind) -> Self? { allCases.first { $0.positive == kind || $0.negative == kind } }
}

enum PlayerGesturePairAction: String, CaseIterable, Identifiable {
    case none, seek, volume, brightness, speed, playback, fill, orientation
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .none: "无操作"; case .seek: "调整播放进度"; case .volume: "调整音量"
        case .brightness: "调整亮度"; case .speed: "调整播放速度"; case .playback: "控制播放状态"
        case .fill: "调整填充方式"; case .orientation: "调整屏幕方向"
        }
    }
    func action(positive: Bool) -> PlayerGestureAction {
        switch self {
        case .none: .none; case .seek: positive ? .forward : .backward
        case .volume: positive ? .volumeUp : .volumeDown; case .brightness: positive ? .brightnessUp : .brightnessDown
        case .speed: positive ? .speedUp : .speedDown; case .playback: positive ? .play : .pause
        case .fill: positive ? .fillScreen : .fitScreen; case .orientation: positive ? .landscape : .portrait
        }
    }
}

enum PlayerGesturePreferences {
    static func boundaries(for count: Int) -> [CGFloat] {
        if count == 1 { return [] }
        let defaults = UserDefaults.standard
        if count == 2 { return [CGFloat(defaults.object(forKey: "player.gesture.split2") as? Double ?? 0.5).clamped(to: 0.15...0.85)] }
        let first = CGFloat(defaults.object(forKey: "player.gesture.split3.first") as? Double ?? 1.0 / 3).clamped(to: 0.15...0.7)
        let second = CGFloat(defaults.object(forKey: "player.gesture.split3.second") as? Double ?? 2.0 / 3).clamped(to: (first + 0.15)...0.85)
        return [first, second]
    }
    static func regions(for count: Int) -> [PlayerGestureRegion] { count == 1 ? [.center] : (count == 2 ? [.left, .right] : PlayerGestureRegion.allCases) }
    static func pairEnabled(_ pair: PlayerGesturePair, _ fingers: Int) -> Bool {
        UserDefaults.standard.object(forKey: "player.gesture.paired.\(fingers).\(pair.rawValue)") as? Bool ?? true
    }
    static func layoutID(_ kind: PlayerGestureKind, _ fingers: Int) -> String {
        if let pair = PlayerGesturePair.containing(kind), pairEnabled(pair, fingers) { return "pair.\(pair.rawValue)" }
        return kind.rawValue
    }
    static func layoutKey(_ kind: PlayerGestureKind, _ fingers: Int) -> String { "player.gesture.layout.\(fingers).\(layoutID(kind, fingers))" }
    static func count(for kind: PlayerGestureKind, fingers: Int) -> Int {
        let defaults = UserDefaults.standard
        let fallback = defaultCount(for: kind, fingers: fingers)
        let count = defaults.object(forKey: layoutKey(kind, fingers)) as? Int ?? fallback
        return (1...3).contains(count) ? count : fallback
    }
    static func defaultCount(for kind: PlayerGestureKind, fingers: Int) -> Int {
        if fingers == 1 {
            if kind == .up || kind == .down { return 2 }
            if kind == .doubleTap { return 3 }
        }
        return 1
    }
    static func region(at point: CGPoint, width: CGFloat, kind: PlayerGestureKind, fingers: Int) -> PlayerGestureRegion {
        .at(point, width: width, count: count(for: kind, fingers: fingers))
    }
    static func key(_ kind: PlayerGestureKind, _ region: PlayerGestureRegion, _ fingers: Int) -> String { "player.gesture.\(fingers).\(region.rawValue).\(kind.rawValue)" }
    static func pairKey(_ pair: PlayerGesturePair, _ region: PlayerGestureRegion, _ fingers: Int) -> String { "player.gesture.pairAction.\(fingers).\(pair.rawValue).\(region.rawValue)" }
    static func pairAction(_ pair: PlayerGesturePair, _ region: PlayerGestureRegion, _ fingers: Int) -> PlayerGesturePairAction {
        if let saved = UserDefaults.standard.string(forKey: pairKey(pair, region, fingers)), let value = PlayerGesturePairAction(rawValue: saved) { return value }
        if fingers == 2 {
            switch pair {
            case .vertical: return .none
            case .horizontal: return .speed
            case .pinch: return .fill
            }
        }
        if pair == .horizontal { return .seek }
        if pair == .vertical { return region == .left ? .brightness : (region == .right ? .volume : .none) }
        return .none
    }
    static func action(_ kind: PlayerGestureKind, _ region: PlayerGestureRegion, _ fingers: Int) -> PlayerGestureAction {
        if let pair = PlayerGesturePair.containing(kind), pairEnabled(pair, fingers) { return pairAction(pair, region, fingers).action(positive: kind == pair.positive) }
        if let saved = UserDefaults.standard.string(forKey: key(kind, region, fingers)), let action = PlayerGestureAction(rawValue: saved) { return action }
        if kind == .longPress { return .none }
        if fingers == 2 { return kind == .doubleTap ? .close : .none }
        switch kind {
        case .tap: return .controls
        case .doubleTap: return region == .left ? .backward : (region == .right ? .forward : .playback)
        case .up: return region == .left ? .brightnessUp : (region == .right ? .volumeUp : .none)
        case .down: return region == .left ? .brightnessDown : (region == .right ? .volumeDown : .none)
        case .left: return .backward
        case .right: return .forward
        default: return .none
        }
    }
    static var skipInterval: Double {
        let saved = UserDefaults.standard.double(forKey: "player.gesture.skipSeconds")
        return [5.0, 10, 15, 30].contains(saved) ? saved : 15
    }
    static func reset() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("player.gesture.") && key != "player.gesture.skipSeconds" { UserDefaults.standard.removeObject(forKey: key) }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}

/// Only the unobstructed video receives playback gestures; native controls own their touches.
struct PlayerGestureSurface: UIViewRepresentable {
    var tapped: (PlayerGestureRegion, Int, Bool) -> Void
    var held: (PlayerGestureRegion, Int) -> Void
    var panned: (PlayerGestureRegion, Int, PlayerGestureKind, CGFloat, UIGestureRecognizer.State) -> Void
    func makeUIView(context: Context) -> GestureView { GestureView() }
    func updateUIView(_ view: GestureView, context: Context) { view.tapped = tapped; view.panned = panned; view.held = held }

    final class GestureView: UIView, UIGestureRecognizerDelegate {
        var tapped: ((PlayerGestureRegion, Int, Bool) -> Void)?
        var held: ((PlayerGestureRegion, Int) -> Void)?
        var panned: ((PlayerGestureRegion, Int, PlayerGestureKind, CGFloat, UIGestureRecognizer.State) -> Void)?
        private var region = PlayerGestureRegion.center
        private var fingers = 1
        private var axis: PlayerGestureKind?
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isMultipleTouchEnabled = true
            var taps: [UITapGestureRecognizer] = []
            for count in 1...2 {
                let single = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
                single.numberOfTouchesRequired = count
                let double = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
                double.numberOfTouchesRequired = count; double.numberOfTapsRequired = 2
                single.require(toFail: double)
                taps.append(contentsOf: [single, double])
            }
            for tap in taps {
                for other in taps where other.numberOfTouchesRequired > tap.numberOfTouchesRequired { tap.require(toFail: other) }
                addGestureRecognizer(tap)
            }
            for count in 1...2 {
                let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
                hold.numberOfTouchesRequired = count
                hold.minimumPressDuration = 0.5
                addGestureRecognizer(hold)
                for tap in taps { tap.require(toFail: hold) }
            }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.maximumNumberOfTouches = 2
            addGestureRecognizer(pan)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            addGestureRecognizer(pinch)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func tap(_ sender: UITapGestureRecognizer) {
            let kind: PlayerGestureKind = sender.numberOfTapsRequired == 2 ? .doubleTap : .tap
            tapped?(PlayerGesturePreferences.region(at: sender.location(in: self), width: bounds.width, kind: kind, fingers: sender.numberOfTouchesRequired), sender.numberOfTouchesRequired, sender.numberOfTapsRequired == 2)
        }
        @objc private func hold(_ sender: UILongPressGestureRecognizer) {
            guard sender.state == .began else { return }
            let fingers = sender.numberOfTouchesRequired
            held?(PlayerGesturePreferences.region(at: sender.location(in: self), width: bounds.width, kind: .longPress, fingers: fingers), fingers)
        }
        @objc private func pan(_ sender: UIPanGestureRecognizer) {
            let delta = sender.translation(in: self)
            if sender.state == .began {
                fingers = sender.numberOfTouches
                axis = nil
            }
            var phase = sender.state
            if axis == nil {
                guard max(abs(delta.x), abs(delta.y)) >= 18 else { return }
                let horizontal = abs(delta.x) > abs(delta.y) * 1.2
                let vertical = abs(delta.y) > abs(delta.x) * 1.2
                guard horizontal || vertical else { return }
                axis = horizontal ? (delta.x < 0 ? .left : .right) : (delta.y < 0 ? .up : .down)
                if let axis { region = PlayerGesturePreferences.region(at: CGPoint(x: sender.location(in: self).x - delta.x, y: sender.location(in: self).y - delta.y), width: bounds.width, kind: axis, fingers: fingers) }
                phase = .began
            }
            guard let axis else { return }
            let fraction = (axis == .up || axis == .down) ? delta.y / max(bounds.height, 1) : delta.x / max(bounds.width, 1)
            let sign: CGFloat = (axis == .up || axis == .left) ? -1 : 1
            panned?(region, fingers, axis, max(0, fraction * sign), phase)
            if [.ended, .cancelled, .failed].contains(sender.state) { self.axis = nil }
        }
        @objc private func pinch(_ sender: UIPinchGestureRecognizer) {
            if sender.state == .began {
                let kind: PlayerGestureKind = sender.scale < 1 ? .pinchIn : .pinchOut
                axis = kind; region = PlayerGesturePreferences.region(at: sender.location(in: self), width: bounds.width, kind: kind, fingers: 2)
            }
            guard let axis else { return }
            panned?(region, 2, axis, max(0, (sender.scale - 1) * (axis == .pinchIn ? -1 : 1)), sender.state)
            if [.ended, .cancelled, .failed].contains(sender.state) { self.axis = nil }
        }

    }
}

@MainActor
final class PlayerSystemVolume: ObservableObject {
    @Published private(set) var value: Float = AVAudioSession.sharedInstance().outputVolume
    let view = SystemVolumeView(frame: CGRect(x: 0, y: 0, width: 160, height: 40))
    private var pendingRequest: Float?
    private var observation: NSKeyValueObservation?
    private var pendingValue: (value: Float, deadline: Date)?
    private var reconciliation: Task<Void, Never>?
    private var scheduledUpdate: Task<Void, Never>?
    private var lastRequested: Float?

    init() {
        view.showsRouteButton = false
        view.showsVolumeSlider = true
        view.didAttach = { [weak self] in
            Task { @MainActor in
                await Task.yield()
                self?.applyPendingVolume()
            }
        }
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in
                guard let self else { return }
                if let pending = self.pendingValue {
                    if abs(value - pending.value) < 0.015 { self.pendingValue = nil }
                    else if Date() < pending.deadline { return }
                    else { self.pendingValue = nil }
                }
                self.value = value
            }
        }
    }
    func set(_ value: Float) {
        let requested = min(1, max(0, value))
        pendingRequest = requested
        lastRequested = requested
        self.value = requested
        // Let the native route control finish updating, and coalesce drag samples.
        guard scheduledUpdate == nil else { return }
        scheduledUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(20))
            guard let self else { return }
            self.scheduledUpdate = nil
            self.applyPendingVolume()
        }
    }

    private func applyPendingVolume() {
        // MPVolumeView must be attached before its system slider can change the
        // current output route. Keep requests made before attachment for later.
        guard view.window != nil, let requested = pendingRequest else { return }
        view.layoutIfNeeded()
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        pendingRequest = nil
        // Preserve the native route's range; map normalized volume into it.
        let nativeValue = slider.minimumValue + requested * (slider.maximumValue - slider.minimumValue)
        pendingValue = (requested, Date().addingTimeInterval(0.5))
        slider.isUserInteractionEnabled = true
        slider.isEnabled = true
        slider.setValue(nativeValue, animated: false)
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
        value = requested
        reconciliation?.cancel()
        reconciliation = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
            guard let self else { return }
            self.pendingValue = nil
            let actual = AVAudioSession.sharedInstance().outputVolume
            if abs(actual - requested) > 0.03 {
                AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [SystemVolume] requested=\(requested) actual=\(actual) nativeRange=\(slider.minimumValue)...\(slider.maximumValue)")
            }
            self.value = actual
        }
    }

    func finishAdjustment(origin: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            let actual = AVAudioSession.sharedInstance().outputVolume
            AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [SystemVolume] origin=\(origin) requested=\(self.lastRequested ?? self.value) actual=\(actual) attached=\(self.view.window != nil) route=\(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue))")
        }
    }

    final class SystemVolumeView: MPVolumeView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
        override func layoutSubviews() {
            super.layoutSubviews()
            // Keep the native volume control attached and active, but render our
            // own capsule instead of its tracks and thumb.
            for slider in subviews.compactMap({ $0 as? UISlider }) {
                slider.minimumTrackTintColor = .clear
                slider.maximumTrackTintColor = .clear
                let transparent = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
                slider.setThumbImage(transparent, for: .normal)
                slider.setThumbImage(transparent, for: .highlighted)
            }
        }
        var didAttach: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { didAttach?() }
        }
    }

}

struct PlayerVolumeBridge: UIViewRepresentable {
    let volume: PlayerSystemVolume
    func makeUIView(context: Context) -> MPVolumeView {
        volume.view.tintColor = .clear
        return volume.view
    }
    func updateUIView(_ view: MPVolumeView, context: Context) { }
}

struct PlayerAirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) { }
}

/// Own a stable native menu anchor and observe its public UIKit lifecycle.
/// Playback ticks may update the surrounding SwiftUI view while it is open;
/// neither the active menu nor its actions are replaced until dismissal.
struct PlayerMenuButton: UIViewRepresentable {
    var symbol = "ellipsis"
    var pointSize: CGFloat = 17
    var accessibilityTitle = VesperLocalization.string("更多")
    var makeMenu: () -> UIMenu
    var visibilityChanged: (Bool) -> Void

    func makeUIView(context: Context) -> MenuButton {
        let button = MenuButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)), for: .normal)
        button.tintColor = .white
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        button.accessibilityLabel = accessibilityTitle
        return button
    }
    func updateUIView(_ button: MenuButton, context: Context) {
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)), for: .normal)
        button.visibilityChanged = visibilityChanged
        if !button.isMenuShowing { button.menu = makeMenu() }
    }
    static func dismantleUIView(_ button: MenuButton, coordinator: ()) {
        button.visibilityChanged = nil
        button.menu = nil
    }

    final class MenuButton: UIButton {
        var isMenuShowing = false
        var visibilityChanged: ((Bool) -> Void)?

        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                             willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                             animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
            isMenuShowing = true
            visibilityChanged?(true)
        }
        override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                             willEndFor configuration: UIContextMenuConfiguration,
                                             animator: (any UIContextMenuInteractionAnimating)?) {
            super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
            // Notify at dismissal start so sheet actions don't wait for the
            // full menu animation; freeze its contents until completion.
            visibilityChanged?(false)
            let finished: () -> Void = { [weak self] in self?.isMenuShowing = false }
            if let animator { animator.addCompletion(finished) }
            else { finished() }
        }
    }
}

/// Use a native control for direct actions beside native menu controls so the
/// glass group does not create different hit-testing paths for its children.
struct PlayerActionButton: UIViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let symbol: String
    var pointSize: CGFloat = 17
    var action: () -> Void
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = .white
        button.addAction(UIAction { _ in context.coordinator.action() }, for: .touchUpInside)
        return button
    }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = isEnabled
        button.alpha = isEnabled ? 1 : 0.35
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)), for: .normal)
        button.accessibilityLabel = title
    }
    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
    }
}

/// One stable hit surface owns both tap and pan; the volume rendering and
/// hidden MPVolumeView never overlap its touch targets.
struct PlayerVolumeTouchSurface: UIViewRepresentable {
    var expanded: Bool
    var tapped: (Bool) -> Void
    var dragged: (CGFloat, UIGestureRecognizer.State) -> Void
    func makeUIView(context: Context) -> TouchView { TouchView() }
    func updateUIView(_ view: TouchView, context: Context) {
        view.expanded = expanded
        view.tapped = tapped
        view.dragged = dragged
    }
    final class TouchView: UIView, UIGestureRecognizerDelegate {
        var expanded = false
        var tapped: ((Bool) -> Void)?
        var dragged: ((CGFloat, UIGestureRecognizer.State) -> Void)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            addGestureRecognizer(pan)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            tap.require(toFail: pan)
            addGestureRecognizer(tap)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            !(gestureRecognizer is UIPanGestureRecognizer) || expanded
        }
        @objc private func tap(_ sender: UITapGestureRecognizer) {
            tapped?(sender.location(in: self).x >= bounds.width - 44)
        }
        @objc private func pan(_ sender: UIPanGestureRecognizer) {
            dragged?(sender.translation(in: self).x, sender.state)
        }
    }
}

/// UI cadence belongs to the scene, not the renderer's media clock. A passive
/// CADisplayLink alone does not request continuous UIKit/SwiftUI updates.
struct PlayerInterfaceRefreshDriver: UIViewRepresentable {
    let isActive: Bool
    var context = "controls"

    func makeUIView(context: Context) -> RefreshView { RefreshView() }

    func updateUIView(_ view: RefreshView, context: Context) {
        view.isActive = isActive
        view.diagnosticContext = self.context
        view.updateLink()
    }

    static func dismantleUIView(_ view: RefreshView, coordinator: ()) {
        view.stop()
    }

    final class RefreshView: UIView {
        var isActive = false
        var diagnosticContext = "controls" {
            didSet {
                if oldValue != diagnosticContext { resetMeasurement() }
            }
        }
        private var link: UIUpdateLink?
        private weak var linkedScene: UIWindowScene?
        private var sampleStart: TimeInterval?
        private var updateCount = 0
        private var didReport = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateLink()
        }

        func updateLink() {
            guard isActive, let scene = window?.windowScene else {
                stop()
                return
            }
            guard link == nil || linkedScene !== scene else { return }
            stop()
            // Bind to the scene so a sheet/menu covering this particular view
            // does not make its UI update request passive or inactive.
            let link = UIUpdateLink(windowScene: scene) { [weak self] _, info in
                self?.measureUpdate(at: info.modelTime)
            }
            let maximum = Float(scene.screen.maximumFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: maximum, maximum: maximum, preferred: maximum
            )
            link.requiresContinuousUpdates = true
            link.isEnabled = true
            linkedScene = scene
            self.link = link
        }

        func stop() {
            link?.isEnabled = false
            link?.requiresContinuousUpdates = false
            link = nil
            linkedScene = nil
            resetMeasurement()
        }

        private func resetMeasurement() {
            sampleStart = nil
            updateCount = 0
            didReport = false
        }

        private func measureUpdate(at time: TimeInterval) {
            guard !didReport else { return }
            guard let start = sampleStart else { sampleStart = time; return }
            updateCount += 1
            let elapsed = time - start
            guard elapsed >= 2 else { return }
            didReport = true
            // This measures scene UI updates, not video FPS or a guarantee of
            // panel refresh. Low Power Mode and thermal limits remain OS-owned.
            let hz = Double(updateCount) / elapsed
            let maximum = linkedScene?.screen.maximumFramesPerSecond ?? 0
            let power = ProcessInfo.processInfo.isLowPowerModeEnabled
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            AppLog.runtimeEntries.append(
                "\(ISO8601DateFormatter().string(from: Date())) [PlayerRefresh] "
                + "context=\(diagnosticContext) uiUpdates=\(String(format: "%.1f", hz))Hz "
                + "requested=\(maximum)Hz lowPower=\(power) thermal=\(thermal)"
            )
        }
    }
}
