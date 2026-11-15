import SwiftUI

/// Each root page owns its header state; detail navigation stays native.
struct VesperRootScrollView<Actions: View, Content: View>: View {
    let title: LocalizedStringKey
    private let actions: Actions
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.vesperWindowTopInset) private var topInset
    @ScaledMetric(relativeTo: .largeTitle) private var headerContentHeight: CGFloat = 84
    @State private var scrollOffset: CGFloat = 0
    @State private var headerOffset: CGFloat = 0
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
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            max(0, geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, offset in
            scrollOffset = offset
            updateHeader(at: offset)
        }
        .onScrollPhaseChange { oldPhase, newPhase in
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
            .background(VesperTheme.background)
            .opacity(reduceMotion ? 1 - headerOffset / headerHeight : 1)
            .offset(y: reduceMotion ? 0 : -headerOffset)
            .allowsHitTesting(!isCollapsed && headerOffset < headerHeight)
            .accessibilityHidden(isCollapsed)
            .clipped()
        }
        .clipped()
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle(title)
        .toolbar(.hidden, for: .navigationBar)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectHidden(false, for: .top)
    }

    private func updateHeader(at offset: CGFloat) {
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
