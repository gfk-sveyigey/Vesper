import SwiftUI

struct SourcesView: View {
    var body: some View {
        ScrollView {
            ContentUnavailableView {
                Label("尚未配置来源", systemImage: "externaldrive")
            } description: {
                Text("这里将用于配置本地与在线媒体来源，并选择媒体页显示的来源。来源接入将在后续阶段实现。")
            }
            .frame(maxWidth: .infinity)
        }
        .vesperImmersiveTitle("来源")
    }
}
