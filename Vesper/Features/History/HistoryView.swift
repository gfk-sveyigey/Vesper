import SwiftUI

struct HistoryView: View {
    var body: some View {
        ContentUnavailableView {
            Label("暂无播放记录", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("最近播放、观看进度和播放历史将在这里呈现。当前原型尚未接入播放会话。")
        }
        .background(Color("VesperBackground").ignoresSafeArea())
    }
}
