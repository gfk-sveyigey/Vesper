import SwiftUI

struct HistoryView: View {
    @AppStorage("navigation.icons") private var icons = "{}"
    private let testRows = Array(1...20)
    var body: some View {
        if testRows.isEmpty {
            VesperEmptyPage(title: "记录", message: "无记录", symbol: AppSection.history.symbol)
        } else {
            VesperRootScrollView(title: "记录") {
                LazyVStack(spacing: 12) {
                    ForEach(testRows, id: \.self) { index in
                        HStack(spacing: 16) {
                            Image(systemName: AppSection.history.symbol)
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("测试记录 \(index)")
                                    .font(.headline)
                                    .foregroundStyle(Color("VesperPrimaryText"))
                                Text("滚动测试占位，不是真实观看记录。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color("VesperSecondaryBackground"), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}
