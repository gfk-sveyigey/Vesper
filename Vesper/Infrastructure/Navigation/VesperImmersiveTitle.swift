import SwiftUI
import UIKit

/// Attach directly to the root ScrollView/List inside its existing NavigationStack.
private struct VesperImmersiveTitle: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state = ImmersiveTitleState()
    @State private var isTitleCollapsed = false

    func body(content: Content) -> some View {
        content
            .environment(\.vesperTitleCollapsed, isTitleCollapsed)
            .environment(\.vesperTitleBlurProgress, state.blurProgress)
            .onScrollGeometryChange(for: Double.self) { geometry in
                Double(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, offset in
                observe(offset: offset)
            }
            .onScrollPhaseChange { oldPhase, phase, context in
                // Read the final geometry here; the last geometry callback may
                // arrive before or after the phase change.
                let offset = Double(context.geometry.contentOffset.y + context.geometry.contentInsets.top)
                observe(offset: offset, didStop: oldPhase.isScrolling && phase == .idle)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .onDisappear {
                state.settle()
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { isTitleCollapsed = state.isCollapsed }
            }
    }

    private func observe(offset: Double, didStop: Bool = false) {
        guard let transition = state.observe(offset: offset, didStop: didStop) else { return }
        withAnimation(
            .easeInOut(duration: reduceMotion ? 0.18 : 0.30),
            completionCriteria: .logicallyComplete
        ) {
            isTitleCollapsed = transition.isCollapsed
        } completion: {
            state.complete(transition)
        }
    }
}

extension View {
    func vesperImmersiveTitle() -> some View {
        modifier(VesperImmersiveTitle())
    }
}

private struct VesperTitleCollapsedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct VesperTitleBlurProgressKey: EnvironmentKey {
    static let defaultValue: Double = 0
}

private extension EnvironmentValues {
    var vesperTitleBlurProgress: Double {
        get { self[VesperTitleBlurProgressKey.self] }
        set { self[VesperTitleBlurProgressKey.self] = newValue }
    }

    var vesperTitleCollapsed: Bool {
        get { self[VesperTitleCollapsedKey.self] }
        set { self[VesperTitleCollapsedKey.self] = newValue }
    }
}

/// A real scroll-content item, never a fixed overlay. Its layout height stays
/// stable while its contents animate, so scroll geometry cannot feed back.
struct VesperLargeTitle: View {
    let title: String
    @AppStorage("language.code") private var languageCode = "system"
    @Environment(\.vesperTitleCollapsed) private var isCollapsed
    @Environment(\.vesperTitleBlurProgress) private var blurProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var height: CGFloat = 80

    init(_ title: String) { self.title = title }

    var body: some View {
        VesperTitleRendering(
            title: VesperLocalization.string(title, language: languageCode),
            scrollProgress: blurProgress,
            reduceMotion: reduceMotion,
            height: height,
            collapseProgress: isCollapsed ? 1 : 0
        )
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityAddTraits(.isHeader)
        .accessibilityHidden(isCollapsed)
        .allowsHitTesting(false)
    }
}

/// The material occupies only the window's top safe area. It is independent of
/// each scrolling title, and never participates in hit testing.
struct VesperStatusBarMaterial: UIViewControllerRepresentable {
    let diagnosticContext: String

    func makeUIViewController(context: Context) -> StatusBarMaterialController {
        StatusBarMaterialController()
    }

    func updateUIViewController(_ controller: StatusBarMaterialController, context: Context) {
        controller.diagnosticContext = diagnosticContext
        controller.view.setNeedsLayout()
    }

    final class StatusBarMaterialController: UIViewController {
        private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        var diagnosticContext = "" {
            didSet {
                if oldValue != diagnosticContext { scheduleDiagnostic() }
            }
        }
        private var lastDiagnosticContext: String?
        private var diagnosticScheduled = false

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            material.backgroundColor = .clear
            material.isUserInteractionEnabled = false
            view.addSubview(material)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard let window = view.window else { material.frame = .zero; return }
            let strip = CGRect(x: window.bounds.minX, y: window.bounds.minY,
                               width: window.bounds.width, height: window.safeAreaInsets.top)
            material.frame = view.convert(strip, from: window)
            scheduleDiagnostic()
        }

        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            view.setNeedsLayout()
        }

        private func scheduleDiagnostic() {
            guard !diagnosticScheduled, !diagnosticContext.isEmpty,
                  diagnosticContext != lastDiagnosticContext else { return }
            diagnosticScheduled = true
            // Observe after layout, without publishing or changing any UI state.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                diagnosticScheduled = false
                guard let window = viewIfLoaded?.window, window.safeAreaInsets.top > 0,
                      material.bounds.height > 0,
                      diagnosticContext != lastDiagnosticContext else { return }
                lastDiagnosticContext = diagnosticContext
                StatusBarDiagnostics.capture(window: window, material: material, context: diagnosticContext)
            }
        }
    }
}

/// Bounded, event-driven diagnostics. No text, URLs or media data are collected;
/// trace() writes exclusively to the App runtime log, never Xcode Console.
@MainActor
private enum StatusBarDiagnostics {
    static func capture(window: UIWindow, material: UIVisualEffectView, context: String) {
        let id = UUID().uuidString
        let strip = CGRect(x: window.bounds.minX, y: window.bounds.minY,
                           width: window.bounds.width, height: window.safeAreaInsets.top)
        let actualMaterial = material.convert(material.bounds, to: window)
        AppLog.trace("statusbar.trace.begin", detail:
            "id=\(id) \(context) safeTop=\(window.safeAreaInsets.top) strip=\(strip) material=\(actualMaterial) reduceTransparency=\(UIAccessibility.isReduceTransparencyEnabled) style=\(window.traitCollection.userInterfaceStyle.rawValue)")
        var records = 0
        var omitted = 0
        // Include one point below the strip to locate a scroll viewport beginning
        // exactly at the safe-area boundary, even if nothing is drawn above it.
        let probe = strip.insetBy(dx: 0, dy: -1)
        func visit(_ view: UIView, path: String, parentAlpha: CGFloat) {
            let effectiveAlpha = parentAlpha * view.alpha
            if view.isHidden || effectiveAlpha <= 0.001 { return }
            let rect = view.convert(view.bounds, to: window)
            let scroll = view as? UIScrollView
            let relevant = rect.intersects(probe) || scroll != nil
            if relevant {
                if records < 96 {
                    var details = "id=\(id) path=\(path) type=\(String(describing: type(of: view))) rect=\(rect) bg=\(color(view.backgroundColor, traits: view.traitCollection)) alpha=\(effectiveAlpha) opaque=\(view.isOpaque) clips=\(view.clipsToBounds) mask=\(view.layer.mask != nil) rasterized=\(view.layer.shouldRasterize) safeTop=\(view.safeAreaInsets.top)"
                    if let scroll {
                        details += " offsetY=\(scroll.contentOffset.y) insetTop=\(scroll.adjustedContentInset.top) contentHeight=\(scroll.contentSize.height) viewportTop=\(rect.minY)"
                    }
                    AppLog.trace("statusbar.trace.layer", detail: details)
                    records += 1
                } else { omitted += 1 }
            }
            // Do not prune by parent bounds: an unclipped child may draw outside.
            for (index, child) in view.subviews.enumerated() {
                visit(child, path: "\(path)/\(index)", parentAlpha: effectiveAlpha)
            }
        }
        visit(window, path: "0", parentAlpha: 1)
        AppLog.trace("statusbar.trace.end", detail: "id=\(id) records=\(records) omitted=\(omitted)")
    }

    private static func color(_ color: UIColor?, traits: UITraitCollection) -> String {
        guard let color else { return "nil" }
        let resolved = color.resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return String(format: "rgba(%.3f,%.3f,%.3f,%.3f)", Double(red), Double(green), Double(blue), Double(alpha))
        }
        return "unresolved"
    }
}
