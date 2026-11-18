import SwiftUI
import UIKit

/// Each root page owns its header state; detail navigation stays native.
struct VesperRootScrollView<Actions: View, Content: View>: View {
    let title: LocalizedStringKey
    private let actions: Actions
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.vesperWindowTopInset) private var topInset
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

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.content = content()
        self.actions = actions()
    }

    private var animation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.88)
    }

    private var headerHeight: CGFloat {
        headerContentHeight + topInset
    }

    private var contentReachesTitleOffset: CGFloat {
        headerContentHeight - max(0, (headerContentHeight - titleLineHeight) / 2)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: headerHeight)
                    .accessibilityHidden(true)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 20)
                    .environment(\.vesperEmptyContentHeight, max(0, viewportHeight - headerHeight - 20))
            }
            .frame(minHeight: viewportHeight, alignment: .top)
        }
        .scrollClipDisabled()
        .scrollBounceBehavior(.always, axes: .vertical)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                offset: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                viewportHeight: max(0, geometry.containerSize.height - geometry.contentInsets.bottom),
                contentHeight: geometry.contentSize.height
            )
        } action: { _, metrics in
            viewportHeight = metrics.viewportHeight
            contentFitsViewport = metrics.contentHeight <= metrics.viewportHeight + 1
            scrollOffset = metrics.offset
            updateHeader(at: metrics.offset)
        }
        .onScrollPhaseChange { oldPhase, newPhase in
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
        .preference(key: VesperRootHeaderKey.self, value: VesperRootHeaderPresentation(
            header: AnyView(header),
            showsStatusBarBlur: isCollapsed && !contentFitsViewport
        ))
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // The native top effect extends through the navigation/header area.
        // A separately clipped status-bar surface owns the top blur instead.
        .scrollEdgeEffectHidden(true, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .scrollEdgeEffectHidden(false, for: .bottom)
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
