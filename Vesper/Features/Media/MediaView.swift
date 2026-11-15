import SwiftUI

struct MediaView: View {
    @EnvironmentObject private var library: SourceLibrary
    @AppStorage("navigation.icons") private var icons = "{}"

    var body: some View {
        VesperRootScrollView(title: "媒体") {
            VStack(alignment: .leading, spacing: 20) {
                if library.selectedSource == nil {
                    VesperEmptyContent(message: "未选择媒体来源", symbol: AppSection.media.symbol)
                        .frame(maxWidth: .infinity, minHeight: 420)
                } else {
                    switch library.content {
                    case .unselected: EmptyView()
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    case .loaded(let items):
                        if items.isEmpty {
                            VesperEmptyContent(message: "来源中暂无媒体", symbol: AppSection.media.symbol)
                                .frame(maxWidth: .infinity, minHeight: 420)
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
                                        Text(library.selectedSource?.kind == .demo ? "演示内容，不可播放" : "播放功能尚未接入").font(.caption).foregroundStyle(.secondary)
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
            }
        } actions: {
            if !library.sources.isEmpty {
                mediaSourceMenu
            }
        }
        .refreshable { library.reload() }
    }

    private var mediaSourceMenu: some View {
        Menu {
            ForEach(library.sources) { source in
                Button {
                    AppLog.menuDiagnostic("media.select action sourceID=\(source.id)")
                    library.select(source.id)
                } label: {
                    Label {
                        Text(verbatim: source.name)
                    } icon: {
                        Image(systemName: source.id == library.selectedID ? "checkmark" : "folder")
                    }
                }
            }
        } label: {
            Label("选择媒体来源", systemImage: "chevron.down")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .controlSize(.large)
        .frame(width: 48, height: 48)
        .menuDiagnostics("media.select")
    }
}

struct VesperEmptyContent: View {
    let message: LocalizedStringKey
    let symbol: String

    var body: some View {
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
        .padding(.horizontal, 20)
    }
}

struct VesperEmptyPage<Actions: View>: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let symbol: String
    private let actions: Actions

    init(title: LocalizedStringKey, message: LocalizedStringKey, symbol: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.actions = actions()
    }

    var body: some View {
        VesperRootScrollView(title: title) {
            VesperEmptyContent(message: message, symbol: symbol)
                .frame(maxWidth: .infinity, minHeight: 420)
        } actions: {
            actions
        }
    }
}

extension VesperEmptyPage where Actions == EmptyView {
    init(title: LocalizedStringKey, message: LocalizedStringKey, symbol: String) {
        self.init(title: title, message: message, symbol: symbol) { EmptyView() }
    }
}
