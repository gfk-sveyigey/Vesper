import SwiftUI

/// Root pages use the native navigation title and top scroll-edge effect.
private struct VesperRootNavigationTitle: ViewModifier {
    let title: LocalizedStringKey

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inlineLarge)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(false, for: .top)
    }
}

/// Shared root scrolling with native page titles and trailing toolbar actions.
struct VesperRootScrollView<Actions: View, Content: View>: View {
    let title: LocalizedStringKey
    private let actions: Actions
    private let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(.bottom, 20)
        }
        .vesperRootNavigationTitle(title)
        .toolbar {
            if Actions.self != EmptyView.self {
                ToolbarItem(placement: .topBarTrailing) {
                    actions
                }
            }
        }
    }
}

extension VesperRootScrollView where Actions == EmptyView {
    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content) { EmptyView() }
    }
}

extension View {
    func vesperRootNavigationTitle(_ title: LocalizedStringKey) -> some View {
        modifier(VesperRootNavigationTitle(title: title))
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
