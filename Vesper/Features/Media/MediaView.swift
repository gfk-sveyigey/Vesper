import SwiftUI

struct MediaView: View {
    @EnvironmentObject private var library: SourceLibrary

    var body: some View {
        if library.selectedSource == nil {
            VesperEmptyPage(title: "媒体", message: "未选择媒体来源", symbol: "film")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let source = library.selectedSource {
                        Text(verbatim: source.name).font(.headline).padding(.horizontal, 20)
                    }
                    switch library.content {
                    case .unselected: EmptyView()
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    case .loaded(let items):
                        if items.isEmpty {
                            ContentUnavailableView("来源中暂无媒体", systemImage: "film")
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 20) {
                                ForEach(items) { item in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Image(systemName: "film")
                                            .font(.largeTitle)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 150)
                                            .background(Color("VesperSecondaryBackground"), in: RoundedRectangle(cornerRadius: 12))
                                        Text(verbatim: item.title).font(.headline)
                                        Text("演示内容，不可播放").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    case .failed(let error):
                        ContentUnavailableView {
                            Label(LocalizedStringKey(error == .offline ? "来源离线" : "无法加载来源"), systemImage: error == .offline ? "wifi.slash" : "exclamationmark.triangle")
                        } actions: {
                            Button("重试") { library.reload() }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .refreshable { library.reload() }
            .vesperImmersiveTitle("媒体")
        }
    }
}

struct VesperEmptyPage: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let symbol: String
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
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
                .frame(minHeight: geometry.size.height)
            }
        }
        .vesperImmersiveTitle(title)
    }
}
