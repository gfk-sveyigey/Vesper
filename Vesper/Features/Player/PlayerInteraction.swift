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
    static func at(_ point: CGPoint, width: CGFloat) -> Self {
        if point.x < width / 3 { return .left }
        return point.x < width * 2 / 3 ? .center : .right
    }
}

enum PlayerGestureKind: String, CaseIterable, Identifiable {
    case tap, doubleTap, vertical, horizontal
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self { case .tap: "单击"; case .doubleTap: "双击"; case .vertical: "上下滑动"; case .horizontal: "左右滑动" }
    }
    var isDrag: Bool { self == .vertical || self == .horizontal }
}

enum PlayerGestureAction: String, CaseIterable, Identifiable {
    case none, controls, playback, backward, forward, brightness, volume, seek
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .none: "无操作"
        case .controls: "显示或隐藏控制层"
        case .playback: "暂停或继续播放"
        case .backward: "快退"
        case .forward: "快进"
        case .brightness: "调节亮度"
        case .volume: "调节音量"
        case .seek: "调整播放进度"
        }
    }
    static func choices(for kind: PlayerGestureKind) -> [Self] {
        kind.isDrag ? [.none, .brightness, .volume, .seek] : [.none, .controls, .playback, .backward, .forward]
    }
}

enum PlayerGesturePreferences {
    static func key(_ kind: PlayerGestureKind, _ region: PlayerGestureRegion, _ fingers: Int) -> String {
        "player.gesture.\(fingers).\(region.rawValue).\(kind.rawValue)"
    }
    static func action(_ kind: PlayerGestureKind, _ region: PlayerGestureRegion, _ fingers: Int) -> PlayerGestureAction {
        if let saved = UserDefaults.standard.string(forKey: key(kind, region, fingers)), let action = PlayerGestureAction(rawValue: saved), PlayerGestureAction.choices(for: kind).contains(action) { return action }
        guard fingers == 1 else { return .none }
        switch kind {
        case .tap: return .controls
        case .doubleTap: return region == .left ? .backward : (region == .right ? .forward : .playback)
        case .vertical: return region == .left ? .brightness : (region == .right ? .volume : .none)
        case .horizontal: return .seek
        }
    }
    static var skipInterval: Double {
        let saved = UserDefaults.standard.double(forKey: "player.gesture.skipSeconds")
        return [5.0, 10, 15, 30].contains(saved) ? saved : 15
    }
    static func reset() {
        for fingers in 1...3 {
            for region in PlayerGestureRegion.allCases {
                for kind in PlayerGestureKind.allCases { UserDefaults.standard.removeObject(forKey: key(kind, region, fingers)) }
            }
        }
        UserDefaults.standard.removeObject(forKey: "player.gesture.skipSeconds")
    }
}

/// This view is behind the controls, so recognizers never consume button,
/// progress-bar or volume-slider touches. No dismissal gesture is installed.
struct PlayerGestureSurface: UIViewRepresentable {
    var tapped: (PlayerGestureRegion, Int, Bool) -> Void
    var panned: (PlayerGestureRegion, Int, PlayerGestureKind, CGFloat, UIGestureRecognizer.State) -> Void

    func makeUIView(context: Context) -> GestureView { GestureView() }
    func updateUIView(_ view: GestureView, context: Context) {
        view.tapped = tapped
        view.panned = panned
    }

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
            isAccessibilityElement = false
            var taps: [UITapGestureRecognizer] = []
            for count in 1...3 {
                let single = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
                single.numberOfTouchesRequired = count
                let double = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
                double.numberOfTouchesRequired = count
                double.numberOfTapsRequired = 2
                single.require(toFail: double)
                taps.append(contentsOf: [single, double])
            }
            // Wait for higher finger counts before interpreting a one-finger tap.
            for tap in taps {
                for other in taps where other.numberOfTouchesRequired > tap.numberOfTouchesRequired { tap.require(toFail: other) }
                addGestureRecognizer(tap)
            }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = 3
            addGestureRecognizer(pan)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func tap(_ sender: UITapGestureRecognizer) {
            tapped?(.at(sender.location(in: self), width: bounds.width), sender.numberOfTouchesRequired, sender.numberOfTapsRequired == 2)
        }
        @objc private func pan(_ sender: UIPanGestureRecognizer) {
            let translation = sender.translation(in: self)
            if sender.state == .began {
                let location = sender.location(in: self)
                region = .at(CGPoint(x: location.x - translation.x, y: location.y - translation.y), width: bounds.width)
                fingers = sender.numberOfTouches
                axis = abs(translation.y) >= abs(translation.x) ? .vertical : .horizontal
            }
            guard let axis else { return }
            let fraction = axis == .vertical ? -translation.y / max(bounds.height, 1) : translation.x / max(bounds.width, 1)
            panned?(region, fingers, axis, fraction, sender.state)
            if sender.state == .ended || sender.state == .cancelled || sender.state == .failed { self.axis = nil }
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
    var accessibilityTitle = VesperLocalization.string("更多")
    var makeMenu: () -> UIMenu
    var visibilityChanged: (Bool) -> Void

    func makeUIView(context: Context) -> MenuButton {
        let button = MenuButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)), for: .normal)
        button.tintColor = .white
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        button.accessibilityLabel = accessibilityTitle
        return button
    }
    func updateUIView(_ button: MenuButton, context: Context) {
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
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
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
