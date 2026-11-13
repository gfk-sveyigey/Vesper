import SwiftUI

struct MediaView: View {
    var body: some View {
        VesperEmptyPage(title: "媒体", message: "未选择媒体来源", symbol: "film")
    }
}

struct VesperEmptyPage: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let symbol: String
    @State private var titleHeight: CGFloat = 80

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    VesperLargeTitle(title)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
                    VStack(spacing: 16) {
                        Image(systemName: symbol)
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(message)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color("VesperPrimaryText"))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: max(0, geometry.size.height))
                    .offset(y: -titleHeight)
                    .padding(.bottom, -titleHeight)
                }
            }
            .vesperImmersiveTitle(title)
        }
    }
}
