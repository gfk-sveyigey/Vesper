import SwiftUI

/// Each root page owns its header state; detail navigation stays native.
struct VesperRootScrollView<Actions: View, Content: View>: View {
    let title: LocalizedStringKey
    private let actions: Actions
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.vesperWindowTopInset) private var topInset
    @ScaledMetric(relativeTo: .largeTitle) private var headerContentHeight: CGFloat = 60
    @State private var scrollOffset: CGFloat = 0
    @State private var headerOffset: CGFloat = 0
    @State private var canScroll = false
    @State private var isSystemScrolling = false
    @State private var isCollapsed = false
    @State private var isSnapping = false
    @State private var animationGeneration = 0

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

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: headerHeight)
                    .accessibilityHidden(true)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 20)
            }
        }
        .scrollClipDisabled()
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollDisabled(!canScroll)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                offset: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                canScroll: geometry.contentSize.height + geometry.contentInsets.top
                    + geometry.contentInsets.bottom > geometry.containerSize.height + 1
            )
        } action: { _, metrics in
            canScroll = metrics.canScroll
            scrollOffset = metrics.offset
            updateHeader(at: metrics.offset)
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            if newPhase == .animating {
                animationGeneration += 1
                isSnapping = false
                isSystemScrolling = true
                // Start revealing immediately, independently of the distance
                // the system still has to scroll back to the top.
                withAnimation(animation) {
                    isCollapsed = false
                    headerOffset = 0
                }
            } else if newPhase == .interacting || newPhase == .idle {
                if isSystemScrolling && scrollOffset <= 0.5 {
                    headerOffset = 0
                    isCollapsed = false
                }
                isSystemScrolling = false
            }
            if oldPhase == .interacting, newPhase != .interacting,
               !isCollapsed, headerOffset > 0.5, scrollOffset > 0.5 {
                snapHeader()
            }
        }
        .overlay(alignment: .top) {
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
            .opacity(reduceMotion ? 1 - headerOffset / headerHeight : 1)
            .offset(y: reduceMotion ? 0 : -headerOffset)
            .allowsHitTesting(!isCollapsed && headerOffset < headerHeight)
            .accessibilityHidden(isCollapsed)
            .clipped()
        }
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle(title)
        .toolbar(.visible, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .scrollEdgeEffectHidden(false, for: .vertical)
    }

    private func updateHeader(at offset: CGFloat) {
        // Geometry updates must not overwrite the independent return animation.
        guard !isSystemScrolling else { return }
        if offset <= 0.5 {
            guard headerOffset > 0 || isCollapsed || isSnapping else { return }
            animationGeneration += 1
            isSnapping = false
            withAnimation(animation) {
                isCollapsed = false
                headerOffset = 0
            }
        } else if !isCollapsed && !isSnapping {
            headerOffset = max(headerOffset, min(offset, headerHeight))
        }
    }

    private func snapHeader() {
        guard !isSnapping, !isCollapsed else { return }
        isSnapping = true
        isCollapsed = true
        animationGeneration += 1
        let generation = animationGeneration
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            headerOffset = headerHeight
        } completion: {
            guard generation == animationGeneration else { return }
            isSnapping = false
        }
    }

    private struct ScrollMetrics: Equatable {
        let offset: CGFloat
        let canScroll: Bool
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
