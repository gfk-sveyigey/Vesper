import SwiftUI

/// Build 166's top scroll viewport, with the current native inlineLarge title.
private struct VesperRootTopEdge: ViewModifier {
    let title: LocalizedStringKey
    @Environment(\.vesperWindowTopInset) private var windowTopInset

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, windowTopInset, for: .scrollContent)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(false, for: .top)
            .ignoresSafeArea(.container, edges: .top)
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inlineLarge)
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
