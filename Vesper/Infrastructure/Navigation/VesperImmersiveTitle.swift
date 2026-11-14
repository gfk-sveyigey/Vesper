import SwiftUI

/// Root titles live in scroll content; retain the native top scroll edge effect.
private struct VesperRootTopEdge: ViewModifier {
    let title: LocalizedStringKey
    @Environment(\.vesperWindowTopInset) private var windowTopInset

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, windowTopInset, for: .scrollContent)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(false, for: .top)
            .ignoresSafeArea(.container, edges: .top)
            .vesperNavigationTitle(title)
            .vesperNavigationStyle(.inline)
    }
}

/// A content row, never a pinned header or navigation-bar overlay.
struct VesperLargeTitle<Actions: View>: View {
    let title: LocalizedStringKey
    private let actions: Actions

    init(title: LocalizedStringKey, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(Color("VesperPrimaryText"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            actions
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

extension VesperLargeTitle where Actions == EmptyView {
    init(title: LocalizedStringKey) {
        self.init(title: title) { EmptyView() }
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

extension View {
    func vesperImmersiveTitle(_ title: LocalizedStringKey) -> some View {
        modifier(VesperRootTopEdge(title: title))
    }
}
