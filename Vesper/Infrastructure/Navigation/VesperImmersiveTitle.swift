import SwiftUI

/// Attach directly to the root ScrollView/List inside its existing NavigationStack.
private struct VesperImmersiveTitle: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state = ImmersiveTitleState()
    @State private var isTitleCollapsed = false
    @State private var isScrolling = false

    func body(content: Content) -> some View {
        content
            .environment(\.vesperTitleCollapsed, isTitleCollapsed)
            .environment(\.vesperTitleBlurProgress, state.blurProgress)
            .onScrollGeometryChange(for: Double.self) { geometry in
                Double(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, offset in
                observe(offset: offset)
            }
            .onScrollPhaseChange { oldPhase, phase in
                isScrolling = phase.isScrolling
                observe(offset: state.offset, didStop: oldPhase.isScrolling && phase == .idle)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .onDisappear {
                isScrolling = false
                state.settle()
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { isTitleCollapsed = state.isCollapsed }
            }
    }

    private func observe(offset: Double, didStop: Bool = false) {
        guard let transition = state.observe(offset: offset, isScrolling: isScrolling, didStop: didStop) else { return }
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
    let title: LocalizedStringKey
    @Environment(\.vesperTitleCollapsed) private var isCollapsed
    @Environment(\.vesperTitleBlurProgress) private var blurProgress
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
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(blurProgress)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .offset(y: isCollapsed && !reduceMotion ? -height : 0)
            .opacity(isCollapsed ? 0 : 1)
            .clipped()
            .accessibilityAddTraits(.isHeader)
            .accessibilityHidden(isCollapsed)
            .allowsHitTesting(false)
    }
}
