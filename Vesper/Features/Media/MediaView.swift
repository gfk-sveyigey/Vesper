import SwiftUI

struct MediaView: View {
    @EnvironmentObject private var library: SourceLibrary
    @EnvironmentObject private var playback: PlaybackSession
    @AppStorage("navigation.icons") private var icons = "{}"

    var body: some View {
        Group {
            if let source = library.selectedSource, source.kind == .local {
                LocalFilesView(source: source) { mediaSourceMenu }
                    .id(source.id)
            } else {
                mediaContent
            }
        }
    }

    private var mediaContent: some View {
        VesperRootScrollView(title: "媒体") {
            VStack(alignment: .leading, spacing: 20) {
                if library.selectedSource == nil {
                    VesperCenteredEmptyContent(message: "未选择媒体来源", symbol: AppSection.media.symbol)
                } else {
                    switch library.content {
                    case .unselected: EmptyView()
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    case .loaded(let items):
                        if items.isEmpty {
                            VesperCenteredEmptyContent(message: "来源中暂无媒体", symbol: AppSection.media.symbol)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                                ForEach(items) { item in
                                    Button {
                                        guard let source = library.selectedSource else { return }
                                        playback.play(item, in: source, queue: items)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            if let source = library.selectedSource {
                                                MediaThumbnail(source: source, item: item, playback: playback)
                                                    .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback) { EmptyView() })
                                            }
                                            Text(verbatim: item.title).font(.headline)
                                                .lineLimit(1).truncationMode(.tail)
                                            if library.selectedSource?.kind == .demo {
                                                Text("演示内容，不可播放").font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(library.selectedSource?.capabilities.contains(.playback) != true)
                                    .accessibilityLabel(Text(verbatim: item.title))
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
        sourceMenuButton
            .glassEffect(.regular.interactive(), in: .circle)
    }

    private func sourceSymbol(_ source: MediaSource?) -> String {
        switch source?.kind {
        case .photos: "play.rectangle.on.rectangle"
        case .local: "folder"
        case .demo: "play.rectangle"
        case nil: "externaldrive"
        }
    }

    private var sourceMenuButton: some View {
        Menu {
            ForEach(library.sources) { source in
                Button {
                    library.select(source.id)
                } label: {
                    Label {
                        Text(verbatim: source.name)
                    } icon: {
                        Image(systemName: source.id == library.selectedID ? "checkmark" : sourceSymbol(source))
                    }
                }
            }
        } label: {
            Image(systemName: sourceSymbol(library.selectedSource))
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择媒体来源")
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
            VesperCenteredEmptyContent(message: message, symbol: symbol)
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
