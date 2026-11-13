import SwiftUI

/// Each persistent root owns its title state and native scroll edge effect.
private struct VesperImmersiveTitle: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state = ImmersiveTitleState()
    @State private var isTitleCollapsed = false

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                // Expand the scroll viewport beneath the status bar, but keep
                // initial content below it. Scrolling can then carry content
                // through the native edge effect without moving the Host.
                .contentMargins(.top, geometry.safeAreaInsets.top, for: .scrollContent)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectHidden(false, for: .top)
                .ignoresSafeArea(.container, edges: .top)
                .environment(\.vesperTitleCollapsed, isTitleCollapsed)
                .environment(\.vesperTitleFadeProgress, state.fadeProgress)
                .onScrollGeometryChange(for: Double.self) { geometry in
                    Double(geometry.contentOffset.y + geometry.contentInsets.top)
                } action: { _, offset in
                    observe(offset: offset)
                }
                .onScrollPhaseChange { oldPhase, phase, context in
                    let offset = Double(context.geometry.contentOffset.y + context.geometry.contentInsets.top)
                    observe(offset: offset, didStop: oldPhase.isScrolling && phase == .idle)
                }
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

private struct VesperTitleFadeProgressKey: EnvironmentKey {
    static let defaultValue: Double = 0
}

private extension EnvironmentValues {
    var vesperTitleFadeProgress: Double {
        get { self[VesperTitleFadeProgressKey.self] }
        set { self[VesperTitleFadeProgressKey.self] = newValue }
    }

    var vesperTitleCollapsed: Bool {
        get { self[VesperTitleCollapsedKey.self] }
        set { self[VesperTitleCollapsedKey.self] = newValue }
    }
}

/// A scroll-content item with no background, snapshot, or custom blur. Its
/// layout height stays stable so collapse cannot feed back into scroll geometry.
struct VesperLargeTitle: View {
    let title: LocalizedStringKey
    @Environment(\.vesperTitleCollapsed) private var isCollapsed
    @Environment(\.vesperTitleFadeProgress) private var fadeProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var height: CGFloat = 80

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.largeTitle.bold())
            .foregroundStyle(Color("VesperPrimaryText"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            // Natural movement belongs to ScrollView. This independent offset
            // changes only after idle (or when restoring at the very top).
            .offset(y: isCollapsed && !reduceMotion ? -height : 0)
            .opacity(isCollapsed ? 0 : 1 - fadeProgress)
            .clipped()
            .accessibilityAddTraits(.isHeader)
            .accessibilityHidden(isCollapsed || fadeProgress >= 1)
            .allowsHitTesting(false)
    }
}
