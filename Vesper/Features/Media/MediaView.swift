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
                        if library.selectedSource?.kind == .emby && !library.canNavigateBack {
                            embyMediaGroups
                        } else if items.isEmpty {
                            VesperCenteredEmptyContent(message: "来源中暂无媒体", symbol: AppSection.media.symbol)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                                ForEach(items) { item in
                                    Button {
                                        guard let source = library.selectedSource else { return }
                                        if item.isContainer { library.open(item) }
                                        else { playback.play(item, in: source, queue: items.filter { !$0.isContainer }) }
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
                            if library.selectedSource?.kind == .emby, library.hasMoreEmbyItems {
                                Button("加载更多") { library.loadMoreEmbyItems() }
                                    .frame(maxWidth: .infinity)
                                    .disabled(library.loadingMore)
                                if library.loadingMore { ProgressView().frame(maxWidth: .infinity) }
                                if let message = library.paginationError {
                                    Text(verbatim: message).foregroundStyle(.secondary)
                                }
                            }
                        }
                    case .failed(let error):
                        if case .message(let message) = error {
                            ContentUnavailableView {
                                Label("无法加载来源", systemImage: "exclamationmark.triangle")
                            } description: { Text(verbatim: message) } actions: {
                                Button("重试") { library.reload() }
                            }
                        } else {
                            ContentUnavailableView {
                                Label(LocalizedStringKey(error == .offline ? "来源离线" : "无法加载来源"), systemImage: error == .offline ? "wifi.slash" : "exclamationmark.triangle")
                            } actions: {
                                Button("重试") { library.reload() }
                            }
                        }
                    }
                }
            }
        } actions: {
            if library.canNavigateBack {
                Button { library.navigateEmbyBack() } label: { Image(systemName: "chevron.left") }
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            if !library.sources.isEmpty {
                mediaSourceMenu
            }
        }
        .refreshable { library.reload() }
    }

    @ViewBuilder
    private var embyMediaGroups: some View {
        if let source = library.selectedSource {
            if library.embyMediaGroups.isEmpty {
                VesperCenteredEmptyContent(message: "来源中暂无媒体", symbol: AppSection.media.symbol)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(library.embyMediaGroups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: group.title)
                                .font(.headline).foregroundStyle(.secondary)
                                .padding(.horizontal, 20)
                            if group.isLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20).padding(.vertical, 16)
                            } else if let errorMessage = group.errorMessage {
                                Text(verbatim: errorMessage)
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20).padding(.vertical, 16)
                            } else if group.items.isEmpty {
                                Text("暂无媒体")
                                    .font(.subheadline).foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20).padding(.vertical, 16)
                            } else {
                                ScrollView(.horizontal) {
                                    LazyHStack(spacing: 12) {
                                        ForEach(group.items) { item in
                                            Group {
                                                if group.id == "all-media" {
                                                    NavigationLink {
                                                        EmbySeriesBrowserView(source: source, groupTitle: item.title,
                                                                              parentID: item.embyItemID ?? item.id.localID)
                                                    } label: {
                                                        mediaGroupCard(item, source: source, landscape: true)
                                                    }
                                                } else {
                                                    NavigationLink {
                                                        EmbyItemDetailView(source: source, item: item)
                                                    } label: {
                                                        mediaGroupCard(item, source: source, landscape: false)
                                                    }
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback) { EmptyView() })
                                            .accessibilityLabel(Text(verbatim: item.title))
                                        }
                                    }
                                    .padding(.horizontal, 20).padding(.vertical, 12)
                                }
                                .scrollIndicators(.hidden)
                                .contentMargins(.horizontal, 0, for: .scrollContent)
                            }
                        }
                    }
                }
            }
        }
    }

    private func mediaGroupCard(_ item: MediaItem, source: MediaSource, landscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaThumbnail(source: source, item: item, playback: playback,
                           aspectRatio: landscape ? 16.0 / 9.0 : 2.0 / 3.0)
                .frame(width: 132, height: landscape ? 74.25 : 198)
            Text(verbatim: item.title)
                .font(.subheadline).lineLimit(1).truncationMode(.tail)
                .frame(width: 132, alignment: .leading)
        }
        .contentShape(Rectangle())
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
        case .emby: "server.rack"
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

struct EmbySeriesBrowserView: View {
    let source: MediaSource
    let groupTitle: String
    let parentID: String
    @State private var items: [MediaItem] = []
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var errorMessage: String?

    private let pageSize = 21
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink {
                        EmbyItemDetailView(source: source, item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            MediaThumbnail(source: source, item: item, aspectRatio: 2.0 / 3.0)
                            Text(verbatim: item.title).font(.subheadline).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if index >= items.count - 5 { loadNextPage() }
                    }
                }
            }
            .padding(12)
            if isLoading { ProgressView().tint(.white).padding() }
            if let errorMessage {
                Button("重试") { self.errorMessage = nil; loadNextPage() }
                    .foregroundStyle(.white).padding()
                Text(verbatim: errorMessage).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .scrollIndicators(.hidden)
        .navigationTitle(groupTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { loadNextPage() }
    }

    private func loadNextPage() {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        let start = items.count
        Task {
            do {
                let page = try await EmbyRepository.shared.items(for: source, parentID: parentID,
                                                                  startIndex: start, limit: pageSize,
                                                                  sortBy: "DateCreated", sortOrder: "Descending")
                items.append(contentsOf: page)
                reachedEnd = page.count < pageSize
                isLoading = false
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
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
