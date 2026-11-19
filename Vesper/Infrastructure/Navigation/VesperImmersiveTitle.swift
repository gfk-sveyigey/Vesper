import SwiftUI
import UIKit

/// Each root page owns its header state; detail navigation stays native.
struct VesperRootScrollView<Actions: View, Content: View>: View {
    let title: LocalizedStringKey
    private let actions: Actions
    private let content: Content
    private let extendsContentUnderHeader: Bool
    private let showsLoading: Bool
    private let usesMediaScrollEdges: Bool
    private let usesNativeNavigationBar: Bool
    private let onVerticalOffsetChange: (CGFloat) -> Void
    private let onTopPullChange: (CGFloat) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.vesperWindowTopInset) private var topInset
    @Environment(\.vesperSwipeNavigationPhase) private var swipeNavigationPhase
    @ScaledMetric(relativeTo: .largeTitle) private var headerContentHeight: CGFloat = 60
    @ScaledMetric(relativeTo: .largeTitle) private var titleLineHeight: CGFloat = 41
    @State private var scrollOffset: CGFloat = 0
    @State private var isInteracting = false
    @State private var headerOffset: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var isSystemScrolling = false
    @State private var isCollapsed = false
    @State private var isSnapping = false
    @State private var animationGeneration = 0
    @State private var contentFitsViewport = true
    @State private var interactionStartOffset: CGFloat = 0
    @State private var interactionStartHeaderOffset: CGFloat = 0
    @State private var interactionStartedCollapsed = false

    init(title: LocalizedStringKey, extendsContentUnderHeader: Bool = false, showsLoading: Bool = false,
         usesMediaScrollEdges: Bool = false, usesNativeNavigationBar: Bool = false,
         onVerticalOffsetChange: @escaping (CGFloat) -> Void = { _ in },
         onTopPullChange: @escaping (CGFloat) -> Void = { _ in },
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.extendsContentUnderHeader = extendsContentUnderHeader
        self.showsLoading = showsLoading
        self.usesMediaScrollEdges = usesMediaScrollEdges
        self.usesNativeNavigationBar = usesNativeNavigationBar
        self.onVerticalOffsetChange = onVerticalOffsetChange
        self.onTopPullChange = onTopPullChange
        self.content = content()
        self.actions = actions()
    }

    private var animation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.88)
    }

    private var headerHeight: CGFloat {
        usesNativeNavigationBar ? 0 : headerContentHeight + topInset
    }

    private var contentReachesTitleOffset: CGFloat {
        headerContentHeight - max(0, (headerContentHeight - titleLineHeight) / 2)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !usesNativeNavigationBar && !extendsContentUnderHeader {
                    Color.clear.frame(height: headerHeight)
                        .accessibilityHidden(true)
                }
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 20)
                    .environment(\.vesperEmptyContentHeight, max(0, viewportHeight - headerHeight - 20))
            }
            .frame(minHeight: viewportHeight, alignment: .top)
        }
        .scrollDisabled(showsLoading)
        .scrollClipDisabled()
        .scrollBounceBehavior(.always, axes: .vertical)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    guard isInteracting, scrollOffset <= 1, value.translation.height > 0 else { return }
                    onTopPullChange(value.translation.height)
                }
        )
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                offset: geometry.contentOffset.y + geometry.contentInsets.top,
                viewportHeight: max(0, geometry.containerSize.height - geometry.contentInsets.bottom),
                contentHeight: geometry.contentSize.height
            )
        } action: { _, metrics in
            viewportHeight = metrics.viewportHeight
            contentFitsViewport = metrics.contentHeight <= metrics.viewportHeight + 1
            onVerticalOffsetChange(metrics.offset)
            scrollOffset = max(0, metrics.offset)
            if !usesNativeNavigationBar { updateHeader(at: scrollOffset) }
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            if usesNativeNavigationBar {
                isInteracting = newPhase == .interacting
                return
            }
            if newPhase == .animating {
                isSystemScrolling = true
                isInteracting = false
                // Programmatic return must cross the same position gate as
                // dragging. Do not reveal a distant header at animation start.
            } else if newPhase == .interacting {
                // A new drag can interrupt either snap direction.
                animationGeneration += 1
                isSnapping = false
                isInteracting = true
                isSystemScrolling = false
                interactionStartOffset = scrollOffset
                interactionStartHeaderOffset = headerOffset
                interactionStartedCollapsed = isCollapsed
            }

            if oldPhase == .interacting, newPhase != .interacting {
                isInteracting = false
                if contentFitsViewport || scrollOffset <= 0.5 {
                    expandHeader()
                } else if !isSystemScrolling {
                    if interactionStartedCollapsed {
                        // No distance/velocity shortcut can bypass the top gate.
                        settleHeader(collapsed: true)
                    } else {
                        settleHeader(collapsed: headerOffset >= snapThreshold
                            || scrollOffset > contentReachesTitleOffset)
                    }
                }
            }
            if newPhase == .idle { isSystemScrolling = false }
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .scrollEdgeEffectHidden(!showsMediaTopEdge, for: .top)
        .scrollEdgeEffectHidden(usesMediaScrollEdges, for: .bottom)
        .overlay(alignment: .top) {
            // Media's header shares the scroll viewport's top edge without
            // becoming part of the scrolling content or changing its insets.
            if usesMediaScrollEdges && !usesNativeNavigationBar {
                header
            }
        }
        .ignoresSafeArea(.container, edges: !usesNativeNavigationBar || extendsContentUnderHeader ? .top : [])
        .preference(key: VesperRootHeaderKey.self, value: (usesMediaScrollEdges || usesNativeNavigationBar) ? nil : VesperRootHeaderPresentation(
            header: AnyView(header),
            showsStatusBarBlur: !contentFitsViewport && isCollapsed
        ))
        .overlay(alignment: .top) {
            Group {
                if showsLoading {
                    VesperPageLoadingOverlay()
                        .ignoresSafeArea(.container, edges: [.top, .bottom])
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsLoading)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .toolbarVisibility(usesMediaScrollEdges && !usesNativeNavigationBar ? .hidden : .visible, for: .navigationBar)
        .modifier(VesperSwipeNavigationBackground(enabled: usesNativeNavigationBar, phase: swipeNavigationPhase))
        .toolbar {
            if usesNativeNavigationBar {
                ToolbarItem(placement: .topBarTrailing) { actions }
            } else {
                ToolbarItem(placement: .principal) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    private var showsMediaTopEdge: Bool {
        if usesNativeNavigationBar { return swipeNavigationPhase == .hidden }
        return usesMediaScrollEdges && !contentFitsViewport && scrollOffset > 0.5
            && (isCollapsed || headerOffset > 0.5)
    }

    private var snapThreshold: CGFloat { headerHeight * 0.1125 }

    private var headerProgress: CGFloat {
        // The lower edge reaches the status bar's lower edge after travelling
        // just the content-row height (the safe-area inset is not fade travel).
        min(1, max(0, headerOffset / max(headerContentHeight, 1)))
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(Color("VesperPrimaryText"))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            actions
        }
        .padding(.horizontal, 20)
        .frame(height: headerContentHeight)
        .padding(.top, topInset)
        .frame(maxWidth: .infinity)
        .modifier(VesperHeaderMotionEffect(
            displacement: headerOffset,
            fadeDistance: headerContentHeight,
            reducesMotion: reduceMotion
        ))
        .allowsHitTesting(headerProgress < 1 && !isSnapping)
        .accessibilityHidden(headerProgress >= 1)
    }

    private func updateHeader(at offset: CGFloat) {
        if contentFitsViewport {
            if headerOffset > 0 || isCollapsed || isSnapping { expandHeader() }
            return
        }
        if offset <= 0.5 {
            if headerOffset > 0 || isCollapsed || isSnapping { expandHeader() }
            return
        }
        guard !isSystemScrolling, !isSnapping, isInteracting else { return }
        let distance = offset - interactionStartOffset
        if interactionStartedCollapsed {
            // Content begins below the header's default lower edge only at
            // offset zero. Keep the header hidden until that edge is reached.
            return
        } else {
            // An expanded header follows the drag. Small movements settle
            // back unless the content crossed the mandatory-collapse edge.
            headerOffset = min(headerHeight, max(0, interactionStartHeaderOffset + distance))
        }
    }

    private func expandHeader() {
        animationGeneration += 1
        isSnapping = false
        isCollapsed = false
        withAnimation(animation) { headerOffset = 0 }
    }

    private func settleHeader(collapsed: Bool) {
        guard !isSnapping else { return }
        isSnapping = true
        isCollapsed = collapsed
        animationGeneration += 1
        let generation = animationGeneration
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            headerOffset = collapsed ? headerHeight : 0
        } completion: {
            guard generation == animationGeneration else { return }
            isSnapping = false
        }
    }

    private struct ScrollMetrics: Equatable {
        let offset: CGFloat
        let viewportHeight: CGFloat
        let contentHeight: CGFloat
    }

}

/// One interpolated position drives all header effects. Independently animating
/// a clamped blur/opacity target would spread the fade over the entire snap
/// distance, making the blur appear detached from the moving header.
private struct VesperHeaderMotionEffect: AnimatableModifier {
    nonisolated var displacement: CGFloat
    let fadeDistance: CGFloat
    let reducesMotion: Bool

    nonisolated var animatableData: CGFloat {
        get { displacement }
        set { displacement = newValue }
    }

    func body(content: Content) -> some View {
        let progress = min(1, max(0, displacement / max(fadeDistance, 1)))
        content
            // Treat the header's foreground as one composited effect group,
            // not a screen-sized backdrop or a separate stationary blur layer.
            .compositingGroup()
            .blur(radius: 8 * progress, opaque: false)
            .clipped()
            .opacity(1 - progress)
            .offset(y: reducesMotion ? 0 : -displacement)
    }
}

extension VesperRootScrollView where Actions == EmptyView {
    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content) { EmptyView() }
    }
}

private struct VesperWindowTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var vesperWindowTopInset: CGFloat {
        get { self[VesperWindowTopInsetKey.self] }
        set { self[VesperWindowTopInsetKey.self] = newValue }
    }
}

/// Lift the root Header above the entire navigation stack without changing
/// UIKit hit-testing, navigation bar visibility, or tab interactions.
private struct VesperRootHeaderPresentation {
    let header: AnyView
    let showsStatusBarBlur: Bool
}

private struct VesperRootHeaderKey: PreferenceKey {
    static var defaultValue: VesperRootHeaderPresentation? { nil }

    static func reduce(value: inout VesperRootHeaderPresentation?, nextValue: () -> VesperRootHeaderPresentation?) {
        if let next = nextValue() { value = next }
    }
}

struct VesperNavigationHeaderLayer: ViewModifier {
    let isRoot: Bool
    @Environment(\.vesperWindowTopInset) private var topInset

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(VesperRootHeaderKey.self, alignment: .top) { presentation in
            if isRoot, let presentation {
                ZStack(alignment: .top) {
                    presentation.header
                    // A graded backdrop blur, with no material card/fill.
                    // Its lower edge fades to clear inside the status bar.
                    VesperStatusBarEdgeBlur()
                        .frame(height: max(0, topInset))
                        .clipped()
                        .opacity(presentation.showsStatusBarBlur ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .ignoresSafeArea(.container, edges: .top)
            }
        }
    }
}

enum VesperSwipeNavigationPhase: Equatable, Sendable {
    case expanded, moving, hidden
}

private struct VesperSwipeNavigationPhaseKey: EnvironmentKey {
    static let defaultValue: VesperSwipeNavigationPhase = .expanded
}

extension EnvironmentValues {
    var vesperSwipeNavigationPhase: VesperSwipeNavigationPhase {
        get { self[VesperSwipeNavigationPhaseKey.self] }
        set { self[VesperSwipeNavigationPhaseKey.self] = newValue }
    }
}

private struct VesperSwipeNavigationBackground: ViewModifier {
    let enabled: Bool
    let phase: VesperSwipeNavigationPhase

    func body(content: Content) -> some View {
        if enabled {
            content
                .toolbarBackground(.regularMaterial, for: .navigationBar)
                .toolbarBackgroundVisibility(phase == .moving ? .visible : .hidden, for: .navigationBar)
        } else {
            content
        }
    }
}

/// Enable UIKit's native swipe-to-hide only while the owning media root is visible.
struct VesperSwipeNavigationBar: UIViewControllerRepresentable {
    let enabled: Bool
    @Binding var phase: VesperSwipeNavigationPhase

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.reportPhase = { phase = $0 }
        controller.setEnabled(enabled)
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: Void) {
        controller.setEnabled(false)
        controller.reportPhase = nil
    }

    final class Controller: UIViewController {
        private var enabled = false
        private var isVisible = false
        private weak var configuredNavigationController: UINavigationController?
        private var previousSwipeSetting = false
        private var displayLink: CADisplayLink?
        private var observeUntil: CFTimeInterval = 0
        private var lastPhase: VesperSwipeNavigationPhase = .expanded
        private var phaseRevision = 0
        var reportPhase: ((VesperSwipeNavigationPhase) -> Void)?

        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            self.view = view
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isVisible = true
            updateNavigationController()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            updateNavigationController()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            isVisible = false
            updateNavigationController()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            observeTransition()
        }

        func setEnabled(_ enabled: Bool) {
            self.enabled = enabled
            updateNavigationController()
        }

        private func updateNavigationController() {
            let activeController = enabled && isVisible ? navigationController : nil
            guard configuredNavigationController !== activeController else { return }
            if let previous = configuredNavigationController {
                previous.barHideOnSwipeGestureRecognizer.removeTarget(self, action: #selector(swipeChanged))
                previous.hidesBarsOnSwipe = previousSwipeSetting
                if !previousSwipeSetting && previous.isNavigationBarHidden {
                    previous.setNavigationBarHidden(false, animated: false)
                }
            }
            stopObserving()
            configuredNavigationController = activeController
            if let activeController {
                previousSwipeSetting = activeController.hidesBarsOnSwipe
                activeController.hidesBarsOnSwipe = true
                activeController.barHideOnSwipeGestureRecognizer.addTarget(self, action: #selector(swipeChanged))
                observeTransition()
            } else {
                publish(.expanded)
            }
        }

        @objc private func swipeChanged() {
            observeTransition()
        }

        private func observeTransition() {
            guard configuredNavigationController != nil else { return }
            // Track the UIKit presentation frame through its settle animation, not just the pan.
            observeUntil = CACurrentMediaTime() + 0.6
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(sampleNavigationBar))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        @objc private func sampleNavigationBar() {
            guard let nav = configuredNavigationController else {
                stopObserving()
                return
            }
            defer {
                if CACurrentMediaTime() >= observeUntil { stopObserving() }
            }
            let bar = nav.navigationBar
            guard let window = nav.viewIfLoaded?.window, bar.bounds.height > 0 else { return }
            if bar.isHidden || bar.window == nil {
                publish(.hidden)
                return
            }
            let frame: CGRect
            let opacity: Float
            if let barLayer = bar.layer.presentation(), let windowLayer = window.layer.presentation() {
                frame = barLayer.convert(barLayer.bounds, to: windowLayer)
                opacity = barLayer.opacity
            } else {
                frame = bar.convert(bar.bounds, to: window)
                opacity = bar.layer.opacity
            }
            let expandedTop = max(window.bounds.minY + window.safeAreaInsets.top,
                                  nav.view.convert(nav.view.bounds, to: window).minY)
            let tolerance = 1 / max(1, window.traitCollection.displayScale)
            if frame.maxY <= expandedTop + tolerance || opacity < 0.01 {
                publish(.hidden)
            } else if frame.minY < expandedTop - tolerance || opacity < 0.99 {
                publish(.moving)
            } else {
                publish(.expanded)
            }
        }

        private func stopObserving() {
            displayLink?.invalidate()
            displayLink = nil
        }

        private func publish(_ phase: VesperSwipeNavigationPhase) {
            guard phase != lastPhase else { return }
            lastPhase = phase
            phaseRevision += 1
            let revision = phaseRevision
            Task { @MainActor [weak self] in
                guard let self, phaseRevision == revision else { return }
                reportPhase?(phase)
            }
        }
    }
}

/// UIKit backdrop blur masked from full strength to clear at the lower edge.
/// The mask changes blur coverage; it does not use private variable-blur APIs.
private struct VesperStatusBarEdgeBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> EdgeBlurView { EdgeBlurView() }
    func updateUIView(_ view: EdgeBlurView, context: Context) {}

    final class EdgeBlurView: UIVisualEffectView {
        private let edgeMask = CAGradientLayer()

        init() {
            super.init(effect: UIBlurEffect(style: .regular))
            isUserInteractionEnabled = false
            edgeMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
            edgeMask.locations = [0, 0.55, 1]
            edgeMask.startPoint = CGPoint(x: 0.5, y: 0)
            edgeMask.endPoint = CGPoint(x: 0.5, y: 1)
            layer.mask = edgeMask
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            edgeMask.frame = bounds
            CATransaction.commit()
        }
    }
}

struct VesperPageLoadingOverlay: View {
    var body: some View {
        VesperTheme.background
            .overlay { ProgressView().controlSize(.large).accessibilityLabel("正在加载") }
            .accessibilityAddTraits(.isModal)
    }
}

private struct VesperEmptyContentHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 420
}

extension EnvironmentValues {
    var vesperEmptyContentHeight: CGFloat {
        get { self[VesperEmptyContentHeightKey.self] }
        set { self[VesperEmptyContentHeightKey.self] = newValue }
    }
}

struct VesperCenteredEmptyContent: View {
    let message: LocalizedStringKey
    let symbol: String
    @Environment(\.vesperEmptyContentHeight) private var height
    var body: some View {
        VesperEmptyContent(message: message, symbol: symbol)
            .frame(maxWidth: .infinity, minHeight: height)
    }
}
