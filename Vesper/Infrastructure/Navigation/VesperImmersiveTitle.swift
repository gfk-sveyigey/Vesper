import SwiftUI

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
    @State private var headerOffset: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var isSystemScrolling = false
    @State private var isCollapsed = false
    @State private var isSnapping = false
    @State private var animationGeneration = 0
    @State private var expandedScrollOrigin: CGFloat = 0
    @State private var isReturningToExpanded = false

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
            .frame(minHeight: viewportHeight + headerHeight, alignment: .top)
        }
        .scrollClipDisabled()
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                offset: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                viewportHeight: max(0, geometry.containerSize.height - geometry.contentInsets.bottom)
            )
        } action: { _, metrics in
            viewportHeight = metrics.viewportHeight
            scrollOffset = metrics.offset
            updateHeader(at: metrics.offset)
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            if newPhase == .animating {
                animationGeneration += 1
                isSnapping = false
                isReturningToExpanded = false
                isSystemScrolling = true
                expandedScrollOrigin = 0
                // System scroll-to-top reveals content and Header together.
                withAnimation(animation) {
                    isCollapsed = false
                    headerOffset = 0
                }
            } else if newPhase == .interacting {
                isSystemScrolling = false
                if isReturningToExpanded {
                    animationGeneration += 1
                    isReturningToExpanded = false
                    isSnapping = false
                    expandedScrollOrigin = scrollOffset
                }
            } else if newPhase == .idle {
                if isReturningToExpanded { expandedScrollOrigin = scrollOffset }
                isReturningToExpanded = false
                isSystemScrolling = false
            }
            if oldPhase == .interacting, newPhase != .interacting,
               !isCollapsed, headerOffset > 0.5, scrollOffset > 0.5 {
                settleHeader(collapsed: headerOffset >= headerHeight * 0.1125 || scrollOffset > contentReachesTitleOffset)
            }
        }
        .preference(key: VesperRootHeaderKey.self, value: AnyView(header))
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
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .scrollEdgeEffectHidden(false, for: .vertical)
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
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .opacity(headerOffset > 0 ? 1 : 0)
        }
        .compositingGroup()
        .blur(radius: 8 * min(1, max(0, headerOffset / headerHeight)))
        .opacity(1 - min(1, max(0, headerOffset / headerHeight)))
        .offset(y: reduceMotion ? 0 : -headerOffset)
        .allowsHitTesting(!isCollapsed && headerOffset < headerHeight)
        .accessibilityHidden(isCollapsed)
        .clipped()
    }

    private func updateHeader(at offset: CGFloat) {
        // Geometry updates must not overwrite the independent return animation.
        guard !isSystemScrolling else { return }
        if offset <= 0.5 {
            guard headerOffset > 0 || isCollapsed || isSnapping else { return }
            animationGeneration += 1
            isSnapping = false
            isReturningToExpanded = false
            expandedScrollOrigin = 0
            withAnimation(animation) {
                isCollapsed = false
                headerOffset = 0
            }
        } else if isReturningToExpanded {
            expandedScrollOrigin = offset
        } else if !isCollapsed && !isSnapping {
            headerOffset = max(headerOffset, min(max(0, offset - expandedScrollOrigin), headerHeight))
        }
    }

    private func settleHeader(collapsed: Bool) {
        guard !isSnapping, !isCollapsed else { return }
        isSnapping = true
        isCollapsed = collapsed
        isReturningToExpanded = !collapsed
        if !collapsed { expandedScrollOrigin = scrollOffset }
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
private struct VesperRootHeaderKey: PreferenceKey {
    static var defaultValue: AnyView? { nil }

    static func reduce(value: inout AnyView?, nextValue: () -> AnyView?) {
        if let next = nextValue() { value = next }
    }
}

struct VesperNavigationHeaderLayer: ViewModifier {
    let isRoot: Bool

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(VesperRootHeaderKey.self, alignment: .top) { header in
            if isRoot, let header {
                header.ignoresSafeArea(.container, edges: .top)
            }
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
