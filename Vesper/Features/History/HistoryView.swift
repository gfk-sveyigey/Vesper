import SwiftUI

struct HistoryView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VesperLargeTitle(title: "记录")
                LazyVStack(spacing: 12) {
                    ForEach(1...20, id: \.self) { index in
                        HStack(spacing: 16) {
                            Image(systemName: "film")
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
            .padding(.bottom, 20)
        }
        .vesperImmersiveTitle("记录")
    }
}
