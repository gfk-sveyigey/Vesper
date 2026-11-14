import SwiftUI

/// Root titles are owned by the native navigation bar. No scroll observers,
/// principal placeholders or page-disappearance state changes are needed.
extension View {
    func vesperImmersiveTitle(_ title: LocalizedStringKey) -> some View {
        navigationTitle(title)
            .toolbarTitleDisplayMode(.inlineLarge)
            .scrollEdgeEffectStyle(.soft, for: .top)
    }
}
