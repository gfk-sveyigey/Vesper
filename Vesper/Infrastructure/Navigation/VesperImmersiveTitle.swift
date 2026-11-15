import SwiftUI

/// Root headers live in scroll content; system navigation remains available.
private struct VesperRootNavigationTitle: ViewModifier {
    let title: LocalizedStringKey
    @Environment(\.vesperWindowTopInset) private var windowTopInset

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, windowTopInset, for: .scrollContent)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(false, for: .top)
    }
}

/// A normal scroll-content row, including any page-specific trailing actions.
struct VesperLargeTitle<Actions: View>: View {
    let title: LocalizedStringKey
    private let actions: Actions
    @ScaledMetric(relativeTo: .largeTitle) private var minimumRowHeight = 52

    init(title: LocalizedStringKey, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(Color("VesperPrimaryText"))
                .frame(maxWidth: .infinity, minHeight: minimumRowHeight, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .allowsHitTesting(false)
            actions
                .fixedSize()
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

/// All root pages, including empty states, use the same viewport and header.
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
                VesperLargeTitle(title: title) { actions }
                content
            }
            .padding(.bottom, 20)
        }
        .vesperRootNavigationTitle(title)
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
