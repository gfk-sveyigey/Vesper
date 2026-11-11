import SwiftUI

struct MediaView: View {
    let openSources: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("尚未选择媒体来源", systemImage: "film")
        } description: {
            Text("媒体页只显示当前选定的一个来源。请先前往来源页完成配置。")
        } actions: {
            Button("前往来源", action: openSources)
                .buttonStyle(.borderedProminent)
        }
        .navigationTitle("媒体")
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}
