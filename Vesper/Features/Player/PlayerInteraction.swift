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

final class VesperAppDelegate: NSObject, UIApplicationDelegate {
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
    case tap, doubleTap, up, down, left, right, pinchIn, pinchOut, rotateClockwise, rotateCounterclockwise
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .tap: "单击"; case .doubleTap: "双击"; case .up: "向上滑动"; case .down: "向下滑动"
        case .left: "向左滑动"; case .right: "向右滑动"; case .pinchIn: "捏合"; case .pinchOut: "张开"
        case .rotateClockwise: "顺时针旋转"; case .rotateCounterclockwise: "逆时针旋转"
        }
    }
    var needsTwoFingers: Bool { [.pinchIn, .pinchOut, .rotateClockwise, .rotateCounterclockwise].contains(self) }
}

enum PlayerGestureAction: String, CaseIterable, Identifiable {
    case none, controls, playback, play, pause, backward, forward, brightnessUp, brightnessDown, volumeUp, volumeDown
    case mute, showRegions, playlist, synopsis, details, rotate, fill, pictureInPicture, close, speedUp, speedDown, moreSettings, subtitles, danmaku, gestures
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .none: "无操作"; case .controls: "显示或隐藏控制层"; case .playback: "暂停或继续播放"
        case .play: "播放"; case .pause: "暂停"; case .backward: "快退"; case .forward: "快进"
        case .brightnessUp: "增大亮度"; case .brightnessDown: "减小亮度"; case .volumeUp: "增大音量"; case .volumeDown: "减小音量"
        case .mute: "静音或取消静音"; case .showRegions: "显示区域划分"; case .playlist: "播放列表"
        case .synopsis: "视频简介"; case .details: "详细信息"; case .rotate: "切换屏幕方向"; case .fill: "切换填充方式"
        case .pictureInPicture: "画中画"; case .close: "关闭"; case .speedUp: "加快播放速度"; case .speedDown: "减慢播放速度"
        case .moreSettings: "更多设置"; case .subtitles: "字幕设置"; case .danmaku: "弹幕设置"; case .gestures: "播放手势"
        }
    }
    static func choices(for kind: PlayerGestureKind) -> [Self] { allCases }
}

enum PlayerGesturePair: String, CaseIterable, Identifiable {
    case vertical, horizontal, pinch, rotation
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self { case .vertical: "上滑／下滑"; case .horizontal: "右滑／左滑"; case .pinch: "张开／捏合"; case .rotation: "顺时针／逆时针旋转" }
    }
    var positive: PlayerGestureKind {
        switch self { case .vertical: .up; case .horizontal: .right; case .pinch: .pinchOut; case .rotation: .rotateClockwise }
    }
    var negative: PlayerGestureKind {
        switch self { case .vertical: .down; case .horizontal: .left; case .pinch: .pinchIn; case .rotation: .rotateCounterclockwise }
    }
    var needsTwoFingers: Bool { self == .pinch || self == .rotation }
    static func containing(_ kind: PlayerGestureKind) -> Self? { allCases.first { $0.positive == kind || $0.negative == kind } }
}

enum PlayerGesturePairAction: String, CaseIterable, Identifiable {
    case none, seek, volume, brightness, speed, playback
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .none: "无操作"; case .seek: "快进／快退"; case .volume: "增大／减小音量"
        case .brightness: "增大／减小亮度"; case .speed: "加快／减慢播放速度"; case .playback: "播放／暂停"
        }
    }
    func action(positive: Bool) -> PlayerGestureAction {
        switch self {
        case .none: .none; case .seek: positive ? .forward : .backward
        case .volume: positive ? .volumeUp : .volumeDown; case .brightness: positive ? .brightnessUp : .brightnessDown
        case .speed: positive ? .speedUp : .speedDown; case .playback: positive ? .play : .pause
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
        UserDefaults.standard.object(forKey: "player.gesture.paired.\(fingers).\(pair.rawValue)") as? Bool ?? false
    }
    static func layoutID(_ kind: PlayerGestureKind, _ fingers: Int) -> String {
        if let pair = PlayerGesturePair.containing(kind), pairEnabled(pair, fingers) { return "pair.\(pair.rawValue)" }
        return kind.rawValue
    }
    static func layoutKey(_ kind: PlayerGestureKind, _ fingers: Int) -> String { "player.gesture.layout.\(fingers).\(layoutID(kind, fingers))" }
    static func count(for kind: PlayerGestureKind, fingers: Int) -> Int {
        let defaults = UserDefaults.standard
        let count = defaults.object(forKey: layoutKey(kind, fingers)) as? Int ?? defaults.object(forKey: "player.gesture.regionCount") as? Int ?? 3
        return (1...3).contains(count) ? count : 3
    }
    static func region(at point: CGPoint, width: CGFloat, kind: PlayerGestureKind, fingers: Int) -> PlayerGestureRegion {
        .at(point, width: width, count: count(for: kind, fingers: fingers))
    }
    static func key(_ kind: PlayerGestureKind, _ region: PlayerGestureRegion, _ fingers: Int) -> String { "player.gesture.\(fingers).\(region.rawValue).\(kind.rawValue)" }
    static func pairKey(_ pair: PlayerGesturePair, _ region: PlayerGestureRegion, _ fingers: Int) -> String { "player.gesture.pairAction.\(fingers).\(pair.rawValue).\(region.rawValue)" }
    static func pairAction(_ pair: PlayerGesturePair, _ region: PlayerGestureRegion, _ fingers: Int) -> PlayerGesturePairAction {
        if let saved = UserDefaults.standard.string(forKey: pairKey(pair, region, fingers)), let value = PlayerGesturePairAction(rawValue: saved) { return value }
        guard fingers == 1 else { return .none }
        if pair == .horizontal { return .seek }
        if pair == .vertical { return region == .left ? .brightness : (region == .right ? .volume : .none) }
        return .none
    }
    static func action(_ kind: PlayerGestureKind, _ region: PlayerGestureRegion, _ fingers: Int) -> PlayerGestureAction {
        if let pair = PlayerGesturePair.containing(kind), pairEnabled(pair, fingers) { return pairAction(pair, region, fingers).action(positive: kind == pair.positive) }
        if let saved = UserDefaults.standard.string(forKey: key(kind, region, fingers)), let action = PlayerGestureAction(rawValue: saved) { return action }
        guard fingers == 1 else { return .none }
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
    var panned: (PlayerGestureRegion, Int, PlayerGestureKind, CGFloat, UIGestureRecognizer.State) -> Void
    func makeUIView(context: Context) -> GestureView { GestureView() }
    func updateUIView(_ view: GestureView, context: Context) { view.tapped = tapped; view.panned = panned }

    final class GestureView: UIView, UIGestureRecognizerDelegate {
        var tapped: ((PlayerGestureRegion, Int, Bool) -> Void)?
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
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.maximumNumberOfTouches = 2
            addGestureRecognizer(pan)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            let rotation = UIRotationGestureRecognizer(target: self, action: #selector(rotate(_:)))
            // Native recognizers arbitrate translation, pinch and rotation.
            addGestureRecognizer(pinch); addGestureRecognizer(rotation)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func tap(_ sender: UITapGestureRecognizer) {
            let kind: PlayerGestureKind = sender.numberOfTapsRequired == 2 ? .doubleTap : .tap
            tapped?(PlayerGesturePreferences.region(at: sender.location(in: self), width: bounds.width, kind: kind, fingers: sender.numberOfTouchesRequired), sender.numberOfTouchesRequired, sender.numberOfTapsRequired == 2)
        }
        @objc private func pan(_ sender: UIPanGestureRecognizer) {
            let delta = sender.translation(in: self)
            if sender.state == .began {
                let location = sender.location(in: self)
                fingers = sender.numberOfTouches
                axis = abs(delta.y) >= abs(delta.x) ? (delta.y < 0 ? .up : .down) : (delta.x < 0 ? .left : .right)
                if let axis { region = PlayerGesturePreferences.region(at: CGPoint(x: location.x - delta.x, y: location.y - delta.y), width: bounds.width, kind: axis, fingers: fingers) }
            }
            guard let axis else { return }
            let fraction = (axis == .up || axis == .down) ? delta.y / max(bounds.height, 1) : delta.x / max(bounds.width, 1)
            let sign: CGFloat = (axis == .up || axis == .left) ? -1 : 1
            panned?(region, fingers, axis, max(0, fraction * sign), sender.state)
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
        @objc private func rotate(_ sender: UIRotationGestureRecognizer) {
            if sender.state == .began {
                let kind: PlayerGestureKind = sender.rotation < 0 ? .rotateCounterclockwise : .rotateClockwise
                axis = kind; region = PlayerGesturePreferences.region(at: sender.location(in: self), width: bounds.width, kind: kind, fingers: 2)
            }
            guard let axis else { return }
            panned?(region, 2, axis, max(0, sender.rotation * (axis == .rotateCounterclockwise ? -1 : 1)) / .pi, sender.state)
            if [.ended, .cancelled, .failed].contains(sender.state) { self.axis = nil }
        }
    }
}

@MainActor
final class PlayerSystemVolume: ObservableObject {
    @Published private(set) var value: Float = AVAudioSession.sharedInstance().outputVolume
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 160, height: 40))
    private var observation: NSKeyValueObservation?

    init() {
        view.showsRouteButton = false
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.value = value }
        }
    }
    func set(_ value: Float) {
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        let value = min(1, max(0, value))
        slider.setValue(value, animated: false)
        slider.sendActions(for: .touchUpInside)
        self.value = value
    }
}

struct PlayerVolumeBridge: UIViewRepresentable {
    let volume: PlayerSystemVolume
    func makeUIView(context: Context) -> MPVolumeView {
        volume.view.tintColor = .white
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
