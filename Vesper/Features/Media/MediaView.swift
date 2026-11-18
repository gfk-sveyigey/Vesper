import SwiftUI
import UIKit

@MainActor
final class MediaLayoutSettings: ObservableObject {
    static let shared = MediaLayoutSettings()

    enum Metric: String, CaseIterable {
        case thumbnailHeight, groupSpacing, titlePadding, scrollPadding
        case itemWidth, itemHeight, itemVerticalPadding, itemSpacing, endPadding

        var defaultValue: Int {
            switch self {
            case .thumbnailHeight, .titlePadding, .scrollPadding: 0
            case .groupSpacing: 24
            case .itemWidth: 88
            case .itemHeight: 132
            case .itemVerticalPadding, .itemSpacing: 12
            case .endPadding: 20
            }
        }

        var range: ClosedRange<Int> {
            switch self {
            case .thumbnailHeight: 0...600
            case .itemWidth, .itemHeight: 24...480
            default: 0...120
            }
        }
    }

    private static let storageKey = "debug.mediaLayout"
    @Published private var values: [String: Int]

    private init() {
        values = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: Int] ?? [:]
    }

    subscript(_ metric: Metric) -> Int {
        get {
            let value = values[metric.rawValue] ?? metric.defaultValue
            return min(max(value, metric.range.lowerBound), metric.range.upperBound)
        }
        set {
            var updated = values
            updated[metric.rawValue] = min(max(newValue, metric.range.lowerBound), metric.range.upperBound)
            values = updated
            UserDefaults.standard.set(updated, forKey: Self.storageKey)
        }
    }

    var thumbnailHeight: CGFloat? {
        let value = self[.thumbnailHeight]
        return value == 0 ? nil : CGFloat(value)
    }

    func reset() {
        values = [:]
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }
}

struct MediaView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject private var library: SourceLibrary
    @EnvironmentObject private var playback: PlaybackSession
    @ObservedObject private var layout = MediaLayoutSettings.shared
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
        .navigationDestination(for: EmbyMediaRoute.self) { route in
            if route.opensLibrary {
                EmbySeriesBrowserView(source: route.source, groupTitle: route.title, parentID: route.itemID)
            } else if let item = route.item {
                EmbyItemDetailView(source: route.source, item: item)
            }
        }
    }

    private var featured: [MediaItem] {
        guard library.selectedSource?.kind == .emby, !library.canNavigateBack,
              case .loaded = library.content else { return [] }
        return EmbyMediaGroup.featured(in: library.embyMediaGroups)
    }

    private var mediaContent: some View {
        let featured = featured
        return VesperRootScrollView(title: "媒体", extendsContentUnderHeader: !featured.isEmpty) {
            VStack(alignment: .leading, spacing: 20) {
                if let source = library.selectedSource, !featured.isEmpty {
                    EmbyFeaturedCarousel(source: source, items: featured)
                }
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
                                                MediaThumbnail(source: source, item: item, playback: playback,
                                                               fixedHeight: layout.thumbnailHeight)
                                                    .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback) { EmptyView() })
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
                VStack(alignment: .leading, spacing: CGFloat(layout[.groupSpacing])) {
                    ForEach(library.embyMediaGroups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            groupTitle(group, source: source)
                            if group.isLoading && group.items.isEmpty {
                                ProgressView()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20).padding(.vertical, 16)
                            } else if let errorMessage = group.errorMessage, group.items.isEmpty {
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
                                    LazyHStack(spacing: CGFloat(layout[.itemSpacing])) {
                                        ForEach(group.items) { item in
                                            groupCard(item, in: group, source: source)
                                        }
                                    }
                                    .padding(.horizontal, CGFloat(layout[.endPadding]))
                                    .padding(.vertical, CGFloat(layout[.itemVerticalPadding]))
                                }
                                .scrollIndicators(.hidden)
                                .contentMargins(.horizontal, 0, for: .scrollContent)
                                .padding(.vertical, CGFloat(layout[.scrollPadding]))
                            }
                        }
                    }
                }
            }
        }
    }

    private func groupTitle(_ group: EmbyMediaGroup, source: MediaSource) -> some View {
        Group {
            if group.id == EmbyMediaGroup.librariesID {
                Text("我的媒体")
            } else {
                NavigationLink(value: EmbyMediaRoute.library(source, id: group.id, title: group.title)) {
                    HStack(spacing: 6) {
                        Text(verbatim: group.title)
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .font(.title2.bold())
        .foregroundStyle(.primary)
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, 20)
        .padding(.vertical, CGFloat(layout[.titlePadding]))
    }

    @ViewBuilder
    private func groupCard(_ item: MediaItem, in group: EmbyMediaGroup, source: MediaSource) -> some View {
        let width = CGFloat(layout[.itemWidth])
        let height = CGFloat(layout[.itemHeight])
        if group.id == EmbyMediaGroup.librariesID {
            let route = EmbyMediaRoute.library(source, id: item.id.localID, title: item.title)
            // Keep the existing landscape proportions at the default settings.
            let landscapeWidth = width * 198 / 88
            let landscapeHeight = height * 111.375 / 132
            NavigationLink(value: route) {
                MediaThumbnail(source: source, item: item, aspectRatio: landscapeWidth / landscapeHeight)
                    .frame(width: landscapeWidth, height: landscapeHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: item.title))
            .contextMenu {
                Button("打开媒体库", systemImage: "arrow.right") { path.append(route) }
            } preview: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: item.title).font(.headline).lineLimit(2)
                    MediaThumbnail(source: source, item: item, aspectRatio: 16.0 / 9.0, cacheOnly: true)
                }
                .padding(12)
                .frame(width: 280)
            }
        } else {
            NavigationLink(value: EmbyMediaRoute.detail(source, item)) {
                MediaThumbnail(source: source, item: item, playback: playback, aspectRatio: width / height)
                    .frame(width: width, height: height)
            }
            .buttonStyle(.plain)
            .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback) { EmptyView() })
            .accessibilityLabel(Text(verbatim: item.title))
        }
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

private struct EmbyFeaturedCarousel: View {
    let source: MediaSource
    let items: [MediaItem]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: MediaID?

    var body: some View {
        TabView(selection: $selection) {
            ForEach(items) { item in
                NavigationLink(value: EmbyMediaRoute.detail(source, item)) {
                    MediaThumbnail(source: source, item: item, aspectRatio: 3.0 / 5.0, cornerRadius: 0)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: item.title))
                .tag(Optional(item.id))
            }
        }
        .tabViewStyle(.page)
        .aspectRatio(3.0 / 5.0, contentMode: .fit)
        .clipped()
        .onChange(of: items.map(\.id), initial: true) { _, ids in
            if selection.map(ids.contains) != true { selection = ids.first }
        }
        .task(id: RotationState(items: items.map(\.id), selection: selection, enabled: canRotate)) {
            guard canRotate, let selection, let current = items.firstIndex(where: { $0.id == selection }) else { return }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            withAnimation { self.selection = items[(current + 1) % items.count].id }
        }
    }

    private var canRotate: Bool {
        items.count > 1 && !reduceMotion && !voiceOverEnabled && scenePhase == .active
    }

    private struct RotationState: Equatable {
        let items: [MediaID]
        let selection: MediaID?
        let enabled: Bool
    }
}

private struct EmbyMediaRoute: Hashable {
    let source: MediaSource
    let title: String
    let itemID: String
    let item: MediaItem?
    var opensLibrary: Bool { item == nil }

    static func library(_ source: MediaSource, id: String, title: String) -> Self {
        Self(source: source, title: title, itemID: id, item: nil)
    }

    static func detail(_ source: MediaSource, _ item: MediaItem) -> Self {
        Self(source: source, title: item.title, itemID: item.id.localID, item: item)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source.id == rhs.source.id && lhs.itemID == rhs.itemID && lhs.opensLibrary == rhs.opensLibrary
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(source.id)
        hasher.combine(itemID)
        hasher.combine(opensLibrary)
    }
}

struct EmbySeriesBrowserView: View {
    let source: MediaSource
    let groupTitle: String
    let parentID: String
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @State private var items: [MediaItem] = []
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var didLoadFirstPage = false
    @State private var nextOffset = 0
    @State private var errorMessage: String?

    private let pageSize = 21
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink(value: EmbyMediaRoute.detail(source, item)) {
                        MediaThumbnail(source: source, item: item, fixedHeight: layout.thumbnailHeight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: item.title))
                    .onAppear {
                        if didLoadFirstPage, index >= items.count - 5, errorMessage == nil {
                            Task { await loadPage() }
                        }
                    }
                }
            }
            .padding(12)
            if isLoading && (items.isEmpty || didLoadFirstPage) { ProgressView().padding() }
            if reachedEnd && items.isEmpty {
                Text("暂无媒体").foregroundStyle(.secondary).padding()
            }
            if let errorMessage {
                Button("重试") { Task { await loadPage() } }
                    .padding()
                Text(verbatim: errorMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .scrollIndicators(.hidden)
        .navigationTitle(groupTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            guard !didLoadFirstPage else { return }
            let cached = await AppCacheStore.shared.items(scope: cacheScope, key: cacheKey)
            guard !Task.isCancelled else { return }
            if let cached, items.isEmpty { items = cached }
            await loadPage()
        }
    }

    private var cacheScope: String { AppCacheStore.scope(for: source) }
    private var cacheKey: String { "browser:\(parentID)" }

    private func loadPage() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let generation = await AppCacheStore.shared.libraryGeneration
            let page = try await EmbyRepository.shared.items(for: source, parentID: parentID,
                                                             startIndex: nextOffset, limit: pageSize,
                                                             sortBy: "DateCreated", sortOrder: "Descending")
            try Task.checkCancellation()
            if !didLoadFirstPage { items = [] }
            var seen = Set(items.map(\.id))
            items.append(contentsOf: page.filter { seen.insert($0.id).inserted })
            nextOffset += page.count
            reachedEnd = page.count < pageSize
            didLoadFirstPage = true
            await AppCacheStore.shared.save(items, scope: cacheScope, key: cacheKey, generation: generation)
        } catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
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
