import SwiftUI
import UIKit
import Network

@MainActor
final class MediaLayoutSettings: ObservableObject {
    static let shared = MediaLayoutSettings()

    enum Metric: String, CaseIterable {
        case thumbnailHeight, groupSpacing, titlePadding, scrollPadding
        case itemWidth, itemHeight, itemVerticalPadding, itemSpacing, endPadding, episodeCardWidth, episodeCardHeight
        case browserListRowHeight, browserListImageTop, browserListImageLeading, browserListImageBottom, browserListImageTrailing

        case mediaHeaderHeight, mediaGlassStrength, mediaGlassTint, mediaContentBlur
        case mediaContentOpacityCurve, mediaContentBlurCurve
        case mediaSnapThreshold, mediaSnapCollapsedThreshold, mediaSnapConflict, mediaSnapDuration, mediaSnapCurve
        case mediaEdgeTopStrength, mediaEdgeTopMaxStrength, mediaEdgeHeightCurve, mediaEdgeBottomStrength, mediaEdgeTint, mediaEdgeCurve

        case carouselBlurHeight, carouselBlurFadeHeight, carouselBlurStrength

        var usesPercent: Bool {
            switch self {
            case .mediaGlassStrength, .mediaGlassTint, .mediaEdgeTopStrength, .mediaEdgeTopMaxStrength, .mediaEdgeBottomStrength, .mediaEdgeTint, .carouselBlurHeight, .carouselBlurStrength: true
            default: false
            }
        }

        var defaultValue: Int {
            switch self {
            case .thumbnailHeight, .titlePadding, .scrollPadding: 0
            case .groupSpacing: 20
            case .itemWidth: 104
            case .itemHeight: 156
            case .itemVerticalPadding, .itemSpacing: 12
            case .endPadding: 20
            case .episodeCardWidth: 246
            case .episodeCardHeight: 230
            case .browserListRowHeight: 132
            case .browserListImageTop, .browserListImageLeading, .browserListImageBottom, .browserListImageTrailing: 8
            case .mediaHeaderHeight: 60
            case .mediaGlassStrength: 65
            case .mediaGlassTint: 12
            case .mediaContentBlur: 8
            case .mediaContentOpacityCurve, .mediaContentBlurCurve: 0
            case .mediaSnapThreshold, .mediaSnapCollapsedThreshold: 50
            case .mediaSnapConflict: 1
            case .mediaSnapDuration: 300
            case .mediaSnapCurve: 3
            case .mediaEdgeTopStrength, .mediaEdgeTopMaxStrength: 100
            case .mediaEdgeBottomStrength: 0
            case .mediaEdgeTint: 12
            case .mediaEdgeCurve, .mediaEdgeHeightCurve: 1
            case .carouselBlurHeight: 40
            case .carouselBlurFadeHeight: 24
            case .carouselBlurStrength: 55
            }
        }

        var range: ClosedRange<Int> {
            switch self {
            case .thumbnailHeight: 0...600
            case .itemWidth, .itemHeight: 24...480
            case .browserListRowHeight: 60...320
            case .browserListImageTop, .browserListImageLeading, .browserListImageBottom, .browserListImageTrailing: 0...60
            case .episodeCardWidth, .episodeCardHeight: 120...1200
            case .mediaHeaderHeight: 30...120
            case .mediaGlassStrength, .mediaGlassTint, .mediaEdgeTopStrength, .mediaEdgeTopMaxStrength, .mediaEdgeBottomStrength, .mediaEdgeTint, .carouselBlurHeight, .carouselBlurStrength: 0...100
            case .mediaContentOpacityCurve, .mediaContentBlurCurve, .mediaEdgeCurve, .mediaEdgeHeightCurve: 0...4
            case .mediaSnapThreshold, .mediaSnapCollapsedThreshold: 5...95
            case .mediaSnapConflict: 0...1
            case .mediaSnapDuration: 100...1000
            case .mediaSnapCurve: 0...4
            case .mediaContentBlur: 0...40
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

    var episodeCardWidth: CGFloat { CGFloat(self[.episodeCardWidth]) }
    var episodeCardHeight: CGFloat { CGFloat(self[.episodeCardHeight]) }

    var carouselBlur: CarouselPosterBlur {
        CarouselPosterBlur(heightFraction: CGFloat(self[.carouselBlurHeight]) / 100,
                           fadeHeight: CGFloat(self[.carouselBlurFadeHeight]),
                           strength: Double(self[.carouselBlurStrength]) / 100)
    }

    func reset(_ metrics: [Metric]) {
        var updated = values
        for metric in metrics {
            updated.removeValue(forKey: metric.rawValue)
        }
        values = updated
        UserDefaults.standard.set(updated, forKey: Self.storageKey)
    }
}

struct MediaView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject private var library: SourceLibrary
    @EnvironmentObject private var playback: PlaybackSession
    @EnvironmentObject private var incomingVideos: IncomingVideoReceiver
    @AppStorage("appearance.accent") private var accent = "vesper"
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @Namespace private var artworkZoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsEmbyShortcuts = false
    @State private var mediaScrollPosition = ScrollPosition(edge: .top)
    @State private var mediaScrollOffset: CGFloat = 0
    @State private var mediaScrollPhase: ScrollPhase = .idle
    @State private var pendingCarouselRoute: EmbyMediaRoute?
    @State private var hidesCarouselInformation = false
    @State private var carouselCrossfade = CarouselDetailCrossfade()
    @State private var localNetworkDenied = false

    var body: some View {
        Group {
            if let source = library.selectedSource, source.kind == .local {
                LocalFilesView(source: source,
                               onVerticalOffsetChange: updateMediaScrollOffset,
                               onVerticalScrollPhaseChange: updateMediaScrollPhase,
                               onTopPullChange: expandEmbyShortcuts(forTopPull:)) { busy, createFolder in
                    mediaSourceMenu(localBusy: busy, createLocalFolder: createFolder)
                }
                    .id(source.id)
            } else {
                mediaContent
            }
        }
        .onChange(of: library.selectedID) { _, _ in
            path = NavigationPath()
            showsEmbyShortcuts = false
            pendingCarouselRoute = nil
            hidesCarouselInformation = false
        }
        .onChange(of: path.isEmpty) { _, isEmpty in
            if !isEmpty {
                pendingCarouselRoute = nil
            } else {
                hidesCarouselInformation = false
            }
        }
        .onDisappear {
            pendingCarouselRoute = nil
        }
        .task(id: pendingCarouselRoute) {
            guard pendingCarouselRoute != nil else { return }
            // Release the pending tap if the scroll is interrupted without reaching the top.
            do {
                try await Task.sleep(for: .seconds(6))
                pendingCarouselRoute = nil
            } catch {
                return
            }
        }
        .navigationDestination(for: EmbyMediaRoute.self) { route in
            if route.opensLibrary || route.opensFavorites {
                EmbySeriesBrowserView(source: route.source, groupTitle: route.title,
                                      parentID: route.opensFavorites ? nil : route.itemID,
                                      scope: route.opensFavorites ? .favorites : .titles,
                                      artworkZoom: artworkZoom, openDetail: { path.append($0) })
            } else if let item = route.item {
                if route.origin == .carousel {
                    let detail = EmbyMediaDetailView(source: route.source, series: item,
                                                      startsWithCarouselInformationHidden: true,
                                                      initialHeroArtwork: library.embyHome?.featuredArtwork?[item.id]
                                                        ?? EmbyFeaturedArtwork(poster: library.embyHome?.artwork?[item.id.localID], logo: nil))
                        .background {
                            CarouselDetailCrossfade.ReturnObserver(transition: carouselCrossfade,
                                                                   reduceMotion: reduceMotion)
                        }
                    detail
                } else if item.isEmbySeries {
                    EmbyMediaDetailView(source: route.source, series: item)
                        .navigationTransition(.zoom(sourceID: route, in: artworkZoom))
                } else {
                    EmbyMediaDetailView(source: route.source, series: item)
                }
            }
        }
    }

    private var featured: [MediaItem] {
        guard library.selectedSource?.kind == .emby, !library.canNavigateBack,
              let source = library.selectedSource, let home = library.embyHome,
              home.scope == AppCacheStore.scope(for: source) else { return [] }
        return home.featured
    }

    private var isLoadingMedia: Bool {
        if library.isLoadingEmbyHome { return true }
        if case .loading = library.content { return true }
        return false
    }

    private var mediaContent: some View {
        let featured = featured
        let showsFeaturedRegion = library.selectedSource?.kind == .emby && !library.canNavigateBack
        let title: LocalizedStringKey = library.selectedSource.map { LocalizedStringKey("\($0.name)") } ?? "媒体"
        return VesperRootScrollView(title: title, extendsContentUnderHeader: showsFeaturedRegion,
                                   showsLoading: isLoadingMedia, usesMediaScrollEdges: true,
                                   scrollPosition: $mediaScrollPosition,
                                   onVerticalOffsetChange: updateMediaScrollOffset,
                                   onVerticalScrollPhaseChange: updateMediaScrollPhase,
                                   onTopPullChange: expandEmbyShortcuts(forTopPull:)) {
            VStack(alignment: .leading, spacing: 20) {
                if let source = library.selectedSource, showsFeaturedRegion {
                    EmbyFeaturedCarousel(source: source, items: featured, artwork: library.embyHome?.artwork,
                                         featuredArtwork: library.embyHome?.featuredArtwork,
                                         isMediaRoot: path.isEmpty && pendingCarouselRoute == nil,
                                         hidesInformation: hidesCarouselInformation,
                                         openDetail: openCarouselDetail)
                }
                if library.selectedSource == nil {
                    VesperCenteredEmptyContent(message: "未选择媒体来源", symbol: AppSection.media.symbol)
                } else if library.selectedSource?.kind == .emby, library.isLoadingEmbyHome, library.embyHome == nil {
                    EmptyView()
                } else if library.selectedSource?.kind == .emby, !library.canNavigateBack, library.embyHome != nil {
                    embyMediaGroups
                } else {
                    switch library.content {
                    case .unselected: EmptyView()
                    case .loading: EmptyView()
                    case .loaded(let items):
                        if items.isEmpty {
                            VesperCenteredEmptyContent(message: "来源中暂无媒体", symbol: AppSection.media.symbol)
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CGFloat(layout[.itemSpacing])), count: 3),
                                      spacing: CGFloat(layout[.itemVerticalPadding]) * 2) {
                                ForEach(items) { item in
                                    Button {
                                        guard let source = library.selectedSource else { return }
                                        if item.isContainer { library.open(item) }
                                        else { playback.play(item, in: source, queue: items.filter { !$0.isContainer }) }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            if let source = library.selectedSource {
                                                MediaThumbnail(source: source, item: item, playback: playback,
                                                               imageOrientation: .portrait,
                                                               fixedHeight: layout.thumbnailHeight)
                                                    .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback) { EmptyView() })
                                                    .modifier(DeviceMediaCardBackground(enabled: source.kind == .local || source.kind == .photos))
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(library.selectedSource?.capabilities.contains(.playback) != true)
                                    .accessibilityLabel(Text(verbatim: item.title))
                                }
                            }
                            .padding(.horizontal, CGFloat(layout[.endPadding]))
                            .padding(.vertical, CGFloat(layout[.itemVerticalPadding] + layout[.scrollPadding]))
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
            .overlay(alignment: .topLeading) {
                // Keep the window anchor inside the scroll content. A UIKit
                // background sibling of the root scroll view breaks native
                // tab reselection scrolling on iOS.
                CarouselDetailCrossfade.Anchor(transition: carouselCrossfade)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } actions: {
            if library.canNavigateBack {
                Button("返回", systemImage: "chevron.left") { library.navigateEmbyBack() }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            if !library.sources.isEmpty {
                mediaSourceMenu()
            }
        }
        .background(VesperTheme.background.ignoresSafeArea())
        .modifier(ConditionalMediaRefresh(enabled: library.selectedSource?.kind != .emby) { [library] in
            library.reload()
        })
        .alert("无法访问本地网络", isPresented: $localNetworkDenied) {
            Button("取消", role: .cancel) {}
            Button("前往设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        } message: {
            Text("请在系统设置中允许 Vesper 访问本地网络，然后重新选择 Emby 来源。")
        }
    }

    @ViewBuilder
    private var embyMediaGroups: some View {
        if let source = library.selectedSource, let home = library.embyHome,
           home.scope == AppCacheStore.scope(for: source) {
            let visibleGroups = home.groups.filter {
                $0.isLoading || !$0.items.isEmpty
            }
            if visibleGroups.isEmpty {
                VesperCenteredEmptyContent(message: "来源中暂无媒体", symbol: AppSection.media.symbol)
            } else {
                VStack(alignment: .leading, spacing: CGFloat(layout[.groupSpacing])) {
                    ForEach(visibleGroups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            groupTitle(group, source: source)
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: CGFloat(layout[.itemSpacing])) {
                                    if group.isLoading {
                                        ForEach(0..<5, id: \.self) { _ in groupPlaceholder(group) }
                                    } else {
                                        ForEach(group.items) { item in
                                            groupCard(item, in: group, source: source, artwork: home.artwork)
                                        }
                                    }
                                }
                                .scrollTargetLayout()
                                .padding(.vertical, CGFloat(layout[.itemVerticalPadding]))
                            }
                            .scrollClipDisabled()
                            .scrollIndicators(.hidden)
                            .contentMargins(.horizontal, CGFloat(layout[.endPadding]), for: .scrollContent)
                            .scrollTargetBehavior(.viewAligned(limitBehavior: .never, anchor: .leading))
                            .padding(.vertical, CGFloat(layout[.scrollPadding]))
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
                        Text(verbatim: group.totalCount.map { "\(group.title) · \($0)" } ?? group.title)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(uiColor: .systemGray2))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.primary)
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, CGFloat(layout[.endPadding]))
        .padding(.vertical, CGFloat(layout[.titlePadding]))
    }

    @ViewBuilder
    private func groupCard(_ item: MediaItem, in group: EmbyMediaGroup, source: MediaSource, artwork: [String: Data]?) -> some View {
        let data = artwork?[item.id.localID]
        let size = groupCardSize(group)
        if group.id == EmbyMediaGroup.librariesID {
            let route = EmbyMediaRoute.library(source, id: item.id.localID, title: item.title)
            NavigationLink(value: route) {
                MediaThumbnail(source: source, item: item, aspectRatio: size.width / size.height,
                               imageOrientation: .landscape,
                               preloadedData: data, artworkIsPrepared: artwork != nil)
                    .frame(width: size.width, height: size.height)
                    .mediaArtworkBorder()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: item.title))
            .contextMenu {
                Button("打开媒体库", systemImage: "arrow.right") { path.append(route) }
            } preview: {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        MediaThumbnail(source: source, item: item, aspectRatio: size.width / size.height,
                                       imageOrientation: .landscape,
                                       cacheOnly: true, preloadedData: data, artworkIsPrepared: artwork != nil)
                            .mediaArtworkBorder()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: item.title).font(.headline).lineLimit(2)
                            EmbyPreviewFacts(item: item)
                        }
                    }
                    .frame(width: 280)
                }
                .padding(12)
            }
        } else {
            let route = EmbyMediaRoute.detail(source, item, origin: .shelf(group.id))
            NavigationLink(value: route) {
                MediaThumbnail(source: source, item: item, playback: playback,
                               aspectRatio: size.width / size.height, imageOrientation: .portrait,
                               preloadedData: data, artworkIsPrepared: artwork != nil)
                    .frame(width: size.width, height: size.height)
                    .mediaArtworkBorder()
                    .matchedTransitionSource(id: route, in: artworkZoom)
            }
            .buttonStyle(.plain)
            .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback,
                                          preloadedData: data, artworkIsPrepared: artwork != nil,
                                          showsEmbyFacts: true, openEmbyDetails: { path.append(route) }) { EmptyView() })
            .accessibilityLabel(Text(verbatim: item.title))
        }
    }

    private func groupPlaceholder(_ group: EmbyMediaGroup) -> some View {
        let size = groupCardSize(group)
        return MediaCardBackdrop()
            .frame(width: size.width, height: size.height)
            .mediaArtworkBorder()
    }

    private func groupCardSize(_ group: EmbyMediaGroup) -> CGSize {
        let isLibraries = group.id == EmbyMediaGroup.librariesID
        let width = CGFloat(layout[.itemWidth]) * (isLibraries ? 2.25 : 1)
        return CGSize(width: width, height: CGFloat(layout[.itemHeight]))
    }

    private var embyHomeSource: MediaSource? {
        guard let source = library.selectedSource, source.kind == .emby, !library.canNavigateBack else { return nil }
        return source
    }

    private var supportsSourceShortcuts: Bool {
        embyHomeSource != nil || library.selectedSource?.kind == .local
    }

    private func updateMediaScrollOffset(_ offset: CGFloat) {
        mediaScrollOffset = offset
        showPendingCarouselDestinationIfAtTop()
        if showsEmbyShortcuts, offset > 1, supportsSourceShortcuts {
            showsEmbyShortcuts = false
        }
    }

    private func expandEmbyShortcuts(forTopPull pull: CGFloat) {
        guard pull >= 18, supportsSourceShortcuts, !showsEmbyShortcuts else { return }
        showsEmbyShortcuts = true
    }

    private func updateMediaScrollPhase(_ phase: ScrollPhase, offset: CGFloat) {
        mediaScrollPhase = phase
        mediaScrollOffset = offset
        if phase == .interacting {
            pendingCarouselRoute = nil
        }
        showPendingCarouselDestinationIfAtTop()
    }

    private var isMediaScrollAtRestAtTop: Bool {
        mediaScrollPhase == .idle && abs(mediaScrollOffset) <= 0.5
    }

    private func openCarouselDetail(_ route: EmbyMediaRoute) {
        guard path.isEmpty, pendingCarouselRoute == nil else { return }
        pendingCarouselRoute = route
        if isMediaScrollAtRestAtTop {
            showPendingCarouselDestinationIfAtTop()
            return
        }
        if reduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                mediaScrollPosition.scrollTo(edge: .top)
            }
        } else {
            withAnimation(.easeOut(duration: 0.28)) {
                mediaScrollPosition.scrollTo(edge: .top)
            }
        }
    }

    private func showPendingCarouselDestinationIfAtTop() {
        guard isMediaScrollAtRestAtTop, let route = pendingCarouselRoute else { return }
        pendingCarouselRoute = nil
        hidesCarouselInformation = true
        Task { @MainActor in
            await Task.yield()
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(180)) }
            guard path.isEmpty, library.selectedID == route.source.id else { return }
            showCarouselDestination(route)
        }
    }

    private func showCarouselDestination(_ route: EmbyMediaRoute) {
        guard path.isEmpty, library.selectedID == route.source.id else { return }
        if !reduceMotion, !carouselCrossfade.coverMediaPage() {
            path.append(route)
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            path.append(route)
        }
    }

    private func mediaSourceMenu(localBusy: Bool = false, createLocalFolder: (() -> Void)? = nil) -> some View {
        let source = embyHomeSource
        let isLocal = library.selectedSource?.kind == .local && createLocalFolder != nil
        let isLocalMedia = library.selectedSource?.kind == .local || library.selectedSource?.kind == .photos
        let isExpanded = (source != nil || isLocal) && showsEmbyShortcuts
        let iconSize: CGFloat = isLocalMedia ? 26 : 20

        return HStack(spacing: 0) {
            if source != nil || isLocal {
                HStack(spacing: 0) {
                    if let source {
                        refreshButton(inMenu: false).frame(width: 44, height: 44)
                        favoritesButton(source, inMenu: false).frame(width: 44, height: 44)
                    } else if let createLocalFolder {
                        localImportButton(busy: localBusy).frame(width: 44, height: 44)
                        localFolderButton(busy: localBusy, action: createLocalFolder).frame(width: 44, height: 44)
                    }
                }
                .labelStyle(.iconOnly)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: isExpanded ? 88 : 0, alignment: .trailing)
                .clipped()
                .opacity(isExpanded ? 1 : 0)
                .allowsHitTesting(isExpanded)
                .accessibilityHidden(!isExpanded)
            }
            sourceMenuButton(localBusy: localBusy, createLocalFolder: createLocalFolder, iconSize: iconSize)
        }
        // A single native glass capsule becomes a circle at its collapsed width.
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isExpanded)
    }

    private func localImportButton(busy: Bool) -> some View {
        Button { incomingVideos.selectVideo() } label: {
            Label { Text("导入视频") } icon: {
                Image(systemName: "document.badge.plus")
                    .renderingMode(.template)
            }
        }.disabled(busy)
    }

    private func localFolderButton(busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text("新建文件夹") } icon: {
                Image(systemName: "folder.badge.plus")
                    .renderingMode(.template)
            }
        }.disabled(busy)
    }

    private func refreshButton(inMenu: Bool = true) -> some View {
        Button { library.reload() } label: {
            Label { Text("刷新页面") } icon: {
                if inMenu { menuSymbol("arrow.clockwise", source: library.selectedSource) }
                else { Image(systemName: "arrow.clockwise") }
            }
        }
        .disabled(library.isLoadingEmbyHome)
    }

    private func favoritesButton(_ source: MediaSource, inMenu: Bool = true) -> some View {
        Button { path.append(EmbyMediaRoute.favorites(source)) } label: {
            Label { Text("收藏媒体") } icon: {
                if inMenu { menuSymbol("heart", source: source) }
                else { Image(systemName: "heart") }
            }
        }
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

    private func statusTint(_ source: MediaSource?, address: String? = nil) -> UIColor? {
        guard let source else { return nil }
        switch library.connectionStatus(for: source, address: address) {
        case .normal, .verified: return nil
        case .checking: return .systemGray
        case .failed: return .black
        }
    }

    // Bake colors into original-rendering images so native menus retain them.
    private func menuSymbol(_ name: String, source: MediaSource?, address: String? = nil) -> Image {
        let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        let icon = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(statusTint(source, address: address) ?? UIColor(VesperTheme.accent(accent)), renderingMode: .alwaysOriginal)
        return icon.map { Image(uiImage: $0).renderingMode(.original) } ?? Image(systemName: name)
    }

    private func sourceMenuIcon(_ source: MediaSource, size: CGFloat, inMenu: Bool = true) -> Image {
        let configuredIcon = source.emby?.iconData.flatMap { UIImage(data: $0) }
        let image = configuredIcon ?? UIImage(named: "EmbyLogo")
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return inMenu ? menuSymbol(sourceSymbol(source), source: source) : Image(systemName: sourceSymbol(source))
        }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let canvas = CGSize(width: size, height: size)
        let icon = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: canvas)
            UIBezierPath(roundedRect: bounds, cornerRadius: size * 0.23).addClip()
            let scale = configuredIcon == nil
                ? min(size / image.size.width, size / image.size.height)
                : max(size / image.size.width, size / image.size.height)
            let width = image.size.width * scale
            let height = image.size.height * scale
            image.draw(in: CGRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
        }
        let rendered = statusTint(source).map { icon.withTintColor($0, renderingMode: .alwaysOriginal) } ?? icon
        return Image(uiImage: rendered).renderingMode(.original)
    }

    private func selectSource(_ source: MediaSource) {
        guard source.id != library.selectedID else {
            library.verifyEmbyConnection(source.id)
            return
        }
        guard source.kind == .emby, let address = source.emby?.serverAddress,
              LocalNetworkPermissionProbe.isLocalAddress(address) else {
            library.select(source.id)
            return
        }
        Task {
            if await LocalNetworkPermissionProbe.check(address) == .denied {
                localNetworkDenied = true
            } else {
                library.select(source.id)
            }
        }
    }

    private func sourceMenuButton(localBusy: Bool, createLocalFolder: (() -> Void)?, iconSize: CGFloat) -> some View {
        Menu {
            if library.selectedSource?.kind == .local, !showsEmbyShortcuts, let createLocalFolder {
                Section {
                    localImportButton(busy: localBusy)
                    localFolderButton(busy: localBusy, action: createLocalFolder)
                }
            }
            if let source = embyHomeSource, !showsEmbyShortcuts {
                Section { refreshButton() }
                Section { favoritesButton(source) }
            }
            Section {
                ForEach(library.sources) { source in
                    Button {
                        selectSource(source)
                    } label: {
                        Label {
                            Text(verbatim: source.name)
                        } icon: {
                            if source.kind == .emby {
                                sourceMenuIcon(source, size: 22)
                            } else {
                                menuSymbol(sourceSymbol(source), source: source)
                            }
                        }
                    }
                    .accessibilityAddTraits(source.id == library.selectedID ? .isSelected : [])
                }
            }
            if let source = library.selectedSource, let configuration = source.emby {
                Section {
                    Menu {
                        ForEach(EmbyRouteOptions.unique([configuration.serverAddress] + (configuration.alternateAddresses ?? [])), id: \.self) { address in
                            Button {
                                library.switchEmbyRoute(source.id, address: address)
                            } label: {
                                Label { Text(verbatim: address) } icon: {
                                    menuSymbol("network",
                                               source: source, address: address)
                                }
                            }
                        }
                    } label: {
                        Label { Text("切换线路") } icon: { menuSymbol("network", source: source) }
                    }
                    .disabled((configuration.alternateAddresses ?? []).isEmpty)
                }
            }
        } label: {
            Group {
                if let source = library.selectedSource, source.kind == .emby {
                    sourceMenuIcon(source, size: 24, inMenu: false)
                } else if let source = library.selectedSource, source.kind == .local || source.kind == .photos {
                    Image(systemName: sourceSymbol(source))
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundStyle(.primary)
                        .contentTransition(.symbolEffect(.replace))
                } else {
                    Image(systemName: sourceSymbol(library.selectedSource))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择媒体来源")
    }
}

enum LocalNetworkPermissionProbe {
    enum Result: Equatable, Sendable { case allowed, denied, unknown }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func run(_ action: () -> Void) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            lock.unlock()
            action()
        }
    }

    static func isLocalAddress(_ address: String) -> Bool {
        guard let components = URLComponents(string: address.contains("://") ? address : "http://\(address)"),
              let host = components.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(Int(octets[1])))
    }

    static func check(_ address: String) async -> Result {
        guard let components = URLComponents(string: address.contains("://") ? address : "http://\(address)"),
              let host = components.host else { return .unknown }
        let rawPort = components.port ?? (components.scheme == "https" ? 443 : 80)
        guard let portValue = UInt16(exactly: rawPort),
              let port = NWEndpoint.Port(rawValue: portValue) else { return .unknown }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        return await withCheckedContinuation { continuation in
            let gate = CompletionGate()
            @Sendable func finish(_ result: Result) {
                gate.run {
                    connection.cancel()
                    continuation.resume(returning: result)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.allowed)
                case .waiting(let error), .failed(let error):
                    if case .posix(let code) = error, code == .EPERM || code == .EACCES {
                        finish(.denied)
                    } else if case .waiting = state {
                        return
                    } else {
                        finish(.unknown)
                    }
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { finish(.unknown) }
        }
    }
}

/// Keeps both page frames stationary while UIKit drives the navigation transition.
@MainActor
private final class CarouselDetailCrossfade {
    private weak var anchor: UIView?
    private weak var mediaWindow: UIWindow?
    private var mediaWindowBounds = CGRect.zero
    private var mediaSnapshot: UIView?
    private weak var pushCover: UIView?
    private weak var returnCover: UIView?

    func coverMediaPage() -> Bool {
        pushCover?.removeFromSuperview()
        mediaSnapshot = nil
        guard let anchor, let window = anchor.window else { return false }
        let frame = window.bounds
        guard let snapshot = snapshot(in: window, frame: frame) else { return false }

        mediaWindow = window
        mediaWindowBounds = window.bounds
        mediaSnapshot = snapshot
        let cover = makeCover(in: window, frame: frame)
        snapshot.frame = cover.bounds
        cover.addSubview(snapshot)
        pushCover = cover

        return true
    }

    func revealDetail() {
        guard let cover = pushCover, cover.alpha == 1 else { return }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
            cover.alpha = 0
        } completion: { _ in
            cover.removeFromSuperview()
        }
    }

    private func crossfadeReturn(using coordinator: any UIViewControllerTransitionCoordinator,
                                 in window: UIWindow) {
        guard returnCover == nil, let mediaSnapshot,
              mediaWindow === window, mediaWindowBounds == window.bounds else { return }

        // Capture the last rendered detail frame before UIKit moves either page.
        let frame = window.bounds
        guard let detail = snapshot(in: window, frame: frame) else { return }
        pushCover?.removeFromSuperview()
        let cover = makeCover(in: window, frame: frame)
        mediaSnapshot.frame = cover.bounds
        cover.addSubview(mediaSnapshot)
        detail.frame = cover.bounds
        cover.addSubview(detail)
        returnCover = cover

        // The same coordinator scrubs the fade during a swipe and reverses it on cancellation.
        let registered = coordinator.animateAlongsideTransition(in: cover) { _ in
            detail.alpha = 0
        } completion: { [weak self, weak cover] context in
            cover?.removeFromSuperview()
            guard let self, let cover, self.returnCover === cover else { return }
            self.returnCover = nil
            if !context.isCancelled { self.mediaSnapshot = nil }
        }
        if !registered {
            cover.removeFromSuperview()
            returnCover = nil
        }
    }

    private func snapshot(in window: UIWindow, frame: CGRect) -> UIView? {
        guard !frame.isEmpty else { return nil }
        return window.resizableSnapshotView(from: frame, afterScreenUpdates: false, withCapInsets: .zero)
    }

    private func makeCover(in window: UIWindow, frame: CGRect) -> UIView {
        let cover = UIView(frame: frame)
        cover.isUserInteractionEnabled = false
        cover.accessibilityElementsHidden = true
        window.addSubview(cover)
        return cover
    }

    struct Anchor: UIViewRepresentable {
        let transition: CarouselDetailCrossfade

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            transition.anchor = view
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {}
    }

    struct ReturnObserver: UIViewControllerRepresentable {
        let transition: CarouselDetailCrossfade
        let reduceMotion: Bool

        func makeUIViewController(context: Context) -> ReturnController {
            let controller = ReturnController()
            controller.view.isUserInteractionEnabled = false
            updateUIViewController(controller, context: context)
            return controller
        }

        func updateUIViewController(_ controller: ReturnController, context: Context) {
            controller.transition = transition
            controller.reduceMotion = reduceMotion
        }
    }

    final class ReturnController: UIViewController {
        weak var transition: CarouselDetailCrossfade?
        var reduceMotion = false
        private weak var navigation: UINavigationController?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            navigation = navigationController
            // The destination is mounted; reveal it without waiting for network data.
            if !reduceMotion { transition?.revealDetail() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard !reduceMotion, let window = view.window,
                  let navigation = navigationController ?? self.navigation,
                  let coordinator = transitionCoordinator ?? navigation.transitionCoordinator,
                  coordinator.isAnimated,
                  let from = coordinator.viewController(forKey: .from),
                  let to = coordinator.viewController(forKey: .to),
                  to === navigation.viewControllers.first,
                  isHosted(by: from) else { return }
            transition?.crossfadeReturn(using: coordinator, in: window)
        }

        private func isHosted(by controller: UIViewController) -> Bool {
            var ancestor = parent
            while let current = ancestor {
                if current === controller { return true }
                ancestor = current.parent
            }
            return false
        }
    }
}

private struct ConditionalMediaRefresh: ViewModifier {
    let enabled: Bool
    let action: @MainActor @Sendable () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.refreshable { [action] in await action() } }
        else { content }
    }
}

private struct EmbyFeaturedCarousel: View {
    let source: MediaSource
    let items: [MediaItem]
    let artwork: [String: Data]?
    let featuredArtwork: [MediaID: EmbyFeaturedArtwork]?
    let isMediaRoot: Bool
    let hidesInformation: Bool
    let openDetail: (EmbyMediaRoute) -> Void
    @Environment(\.vesperRootHeaderHeight) private var headerHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: MediaID?
    @State private var incoming: MediaID?
    @State private var direction = 1
    @State private var progress = 0.0
    @State private var isDragging = false
    @State private var transitionID: UUID?

    private let mirrorFraction: CGFloat = 0.25
    private let travelFraction: CGFloat = 0.25

    var body: some View {
        let hasPosters = !items.isEmpty

        let pages = GeometryReader { geometry in
            let width = geometry.size.width
            if hasPosters {
                let page = currentIndex
                let isTransitioning = isDragging || transitionID != nil
                ZStack {
                    // Keep adjacent artwork mounted so a pan can reveal it immediately.
                    ForEach(visiblePages(around: page)) { item in
                        let isCurrent = item.id == items[page].id
                        let isIncoming = item.id == incoming
                        let shift = reduceMotion ? 0 : CGFloat(direction) * width * travelFraction
                        let images = featuredArtwork?[item.id]
                        let fallback = artwork?[item.id.localID]
                        let route = EmbyMediaRoute.detail(source, item, origin: .carousel)
                        Button { openDetail(route) } label: {
                            EmbyFeaturedPage(source: source, item: item, size: geometry.size,
                                             artwork: fallback, artworkIsPrepared: artwork != nil,
                                             featuredArtwork: images,
                                             featuredArtworkIsPrepared: images != nil,
                                             showsInformation: isCurrent && !isTransitioning && !hidesInformation,
                                             mirroredEdgeFraction: (isCurrent || isIncoming) && isTransitioning && !reduceMotion ? mirrorFraction : 0)
                        }
                        .buttonStyle(EmbyCarouselButtonStyle())
                        .accessibilityLabel(Text(verbatim: item.title))
                        .opacity(isCurrent ? 1 - progress : isIncoming ? progress : 0)
                        .frame(width: width)
                        .offset(x: isCurrent ? -shift * progress : shift * (1 - progress))
                        .padding(.horizontal, width * mirrorFraction)
                        .frame(width: width)
                        .zIndex(isIncoming ? 2 : isCurrent ? 1 : 0)
                        .allowsHitTesting(isCurrent && !isTransitioning)
                        .accessibilityHidden(!isCurrent)
                    }
                }
                .frame(width: width, height: geometry.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(EmbyCarouselPan(enabled: items.count > 1 && transitionID == nil) { state, translation, velocity in
                    handlePan(state, translation: translation, velocity: velocity, width: width)
                })
                .overlay(alignment: .bottom) {
                    if items.count > 1 {
                        EmbyFeaturedPageControl(count: items.count, current: page) { target in
                            guard !isDragging, transitionID == nil, items.indices.contains(target), target != page else { return }
                            let forward = (target - page + items.count) % items.count
                            startTransition(to: target, direction: forward <= items.count - forward ? 1 : -1)
                        }
                        .frame(height: 44)
                        .contentShape(Rectangle())
                        .padding(.bottom, 12)
                        .allowsHitTesting(!isTransitioning)
                    }
                }
                .modifier(EmbyPosterStretch(geometry: geometry))
                .transition(.opacity)
            }
        }

        return EmbyCarouselRevealLayout(headerHeight: headerHeight, progress: hasPosters ? 1 : 0) {
            pages
        }
        .animation(reduceMotion || !hasPosters ? nil : .easeOut(duration: 0.32), value: hasPosters)
        .onChange(of: items.map(\.id), initial: true) { _, ids in
            guard selection.map(ids.contains) != true else { return }
            resetTransition()
            selection = ids.first
        }
        .onDisappear { resetTransition() }
        .task(id: RotationState(selection: selection, enabled: canRotate)) {
            guard canRotate else { return }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard !Task.isCancelled, canRotate else { return }
            startTransition(to: wrappedIndex(currentIndex + 1), direction: 1)
        }
    }

    private var currentIndex: Int { items.firstIndex { $0.id == selection } ?? 0 }

    private func wrappedIndex(_ index: Int) -> Int {
        (index + items.count) % items.count
    }

    private func visiblePages(around page: Int) -> [MediaItem] {
        guard !items.isEmpty else { return [] }
        let neighbors = Set([page, wrappedIndex(page - 1), wrappedIndex(page + 1)])
        return items.enumerated().compactMap { index, item in
            neighbors.contains(index) || item.id == incoming ? item : nil
        }
    }

    private func handlePan(_ state: UIGestureRecognizer.State, translation: CGFloat, velocity: CGFloat, width: CGFloat) {
        guard items.count > 1, transitionID == nil, width > 0 else { return }
        switch state {
        case .began, .changed:
            isDragging = true
            direction = translation <= 0 ? 1 : -1
            incoming = items[wrappedIndex(currentIndex + direction)].id
            progress = min(abs(translation) / width, 1)
        case .ended:
            guard isDragging else { return }
            let projectedDistance = translation + velocity * 0.18
            let advances = abs(translation) >= width * 0.28
                || (abs(projectedDistance) >= width * 0.28 && projectedDistance * translation > 0)
            settle(advances: advances)
        case .cancelled, .failed:
            if isDragging { settle(advances: false) }
        default:
            break
        }
    }

    private func startTransition(to index: Int, direction: Int) {
        guard transitionID == nil, items.indices.contains(index), index != currentIndex else { return }
        self.direction = direction
        incoming = items[index].id
        settle(advances: true)
    }

    private func settle(advances: Bool) {
        let token = UUID()
        let destination = advances ? incoming : nil
        transitionID = token
        isDragging = false
        withAnimation(.easeOut(duration: reduceMotion ? 0.16 : 0.32), completionCriteria: .removed) {
            progress = advances ? 1 : 0
        } completion: {
            guard transitionID == token else { return }
            if let destination { selection = destination }
            resetTransition()
        }
    }

    private func resetTransition() {
        incoming = nil
        progress = 0
        isDragging = false
        transitionID = nil
    }

    private var canRotate: Bool {
        isMediaRoot && items.count > 1 && !isDragging && transitionID == nil && !reduceMotion
            && !voiceOverEnabled && scenePhase == .active
    }

    private struct RotationState: Equatable {
        let selection: MediaID?
        let enabled: Bool
    }
}

/// The compact carousel reserves exactly the root header's height until artwork is ready.
private struct EmbyCarouselRevealLayout: Layout {
    let headerHeight: CGFloat
    nonisolated var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.replacingUnspecifiedDimensions().width
        let width = proposedWidth.isFinite ? proposedWidth : 0
        let posterHeight = width / EmbyPosterLayout.aspectRatio
        let height = headerHeight + (posterHeight - headerHeight) * progress
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.minY),
                              anchor: .top, proposal: ProposedViewSize(bounds.size))
    }
}

private struct EmbyCarouselPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let onPan: (UIGestureRecognizer.State, CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        context.coordinator.enabled = enabled
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.enabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        onPan(recognizer.state, recognizer.translation(in: recognizer.view).x,
              recognizer.velocity(in: recognizer.view).x)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled = false

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var touchedView = touch.view
            while let view = touchedView {
                if view is UIControl { return false }
                touchedView = view.superview
            }
            return true
        }
    }
}

enum EmbyPosterLayout {
    static let aspectRatio: CGFloat = 3.0 / 5.0
    static let informationBottomInset: CGFloat = 132
    static let seriesFooterBottomInset: CGFloat = 14
}

struct EmbyPosterStretch: ViewModifier {
    let geometry: GeometryProxy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let pull = max(0, geometry.frame(in: .scrollView(axis: .vertical)).minY)
        let scale = reduceMotion ? 1 : 1 + min(pull / max(geometry.size.height, 1), 0.08)
        content
            .scaleEffect(scale, anchor: .top)
            .frame(width: geometry.size.width, height: geometry.size.height + pull, alignment: .top)
            .clipped()
            .offset(y: -pull)
    }
}

struct CarouselPosterBlur {
    let heightFraction: CGFloat
    let fadeHeight: CGFloat
    let strength: Double
}

struct EmbyFeaturedPage: View {
    let source: MediaSource
    let item: MediaItem
    let size: CGSize
    let artwork: Data?
    let artworkIsPrepared: Bool
    let featuredArtwork: EmbyFeaturedArtwork?
    let featuredArtworkIsPrepared: Bool
    var initialHeroArtwork: EmbyFeaturedArtwork? = nil
    var crossfadesArtwork = false
    var usesEpisodeArtwork = false
    var episodeContext = ""
    let showsInformation: Bool
    var seriesFooter: EmbySeriesHeroFooter? = nil
    var seriesFooterOpacity: Double = 1
    var mirroredEdgeFraction: CGFloat = 0
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedArtwork: EmbyFeaturedArtwork?
    @State private var loadedArtworkID: MediaID?

    var body: some View {
        let images = featuredArtworkIsPrepared
            ? featuredArtwork
            : loadedArtworkID == item.id ? loadedArtwork : initialHeroArtwork
        Group {
            if usesEpisodeArtwork {
                MediaCardBackdrop(showsMissingArtwork: loadedArtwork != nil && images?.poster == nil, iconCenterY: 1.0 / 3)
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        ZStack {
                            if let data = images?.poster, let image = UIImage(data: data) {
                                EmbyEpisodeArtworkSurface(image: image, size: size)
                                    .id(data.hashValue)
                                    .transition(.opacity)
                            }
                        }
                        .animation(crossfadesArtwork && !reduceMotion ? .easeInOut(duration: 0.3) : nil,
                                   value: images?.poster)
                    }
            } else {
        MediaThumbnail(source: source, item: item, aspectRatio: EmbyPosterLayout.aspectRatio,
                       imageOrientation: usesEpisodeArtwork ? .landscape : .portrait,
                       crossfadesArtwork: crossfadesArtwork, allowsRemotePrimary: false, cornerRadius: 0, fixedHeight: size.height,
                       preloadedData: images?.poster ?? artwork,
                       artworkIsPrepared: images?.poster != nil || artworkIsPrepared,
                       mirroredEdgeFraction: mirroredEdgeFraction,
                       showsMissingArtwork: featuredArtworkIsPrepared || loadedArtwork != nil)
            }
        }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    if !usesEpisodeArtwork { bottomBlur }

                    VStack(spacing: 0) {
                        VStack(spacing: 6) {
                            Group {
                                if !usesEpisodeArtwork, let logo = images?.logo, let image = UIImage(data: logo) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .accessibilityLabel(Text(verbatim: item.title))
                                } else {
                                    Text(verbatim: item.title)
                                        .font(.largeTitle.weight(.semibold))
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.75)
                                }
                            }
                            .frame(maxWidth: size.width * 0.68)
                            .frame(height: size.height * 0.14)
                            VStack(spacing: 4) {
                                Text(verbatim: usesEpisodeArtwork ? episodeContext : firstLine)
                                if !usesEpisodeArtwork && !secondLine.isEmpty { Text(verbatim: secondLine) }
                            }
                            .font(.subheadline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(height: size.height * 0.06)
                        }
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                        .shadow(color: (colorScheme == .dark ? Color.black : Color.white).opacity(0.65), radius: 3, y: 1)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.bottom, seriesFooter == nil ? EmbyPosterLayout.informationBottomInset : 16)
                        .offset(y: seriesFooter == nil ? -24 : 0)
                        .frame(maxWidth: .infinity)
                        .opacity(showsInformation ? 1 : 0)
                        .animation(.easeInOut(duration: 0.16), value: showsInformation)
                        .accessibilityHidden(true)
                        if let seriesFooter {
                            seriesFooter
                                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                                .shadow(color: (colorScheme == .dark ? Color.black : Color.white).opacity(0.65), radius: 3, y: 1)
                                .padding(.horizontal, 20)
                                .padding(.bottom, EmbyPosterLayout.seriesFooterBottomInset)
                                .opacity(seriesFooterOpacity)
                                .accessibilityHidden(seriesFooterOpacity == 0)
                                .allowsHitTesting(seriesFooterOpacity > 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .task(id: item.id) {
                guard !featuredArtworkIsPrepared else { return }
                if loadedArtworkID != item.id {
                    loadedArtwork = nil
                    loadedArtworkID = nil
                }
                let images: EmbyFeaturedArtwork
                if usesEpisodeArtwork {
                    let poster = await MediaThumbnailLoader.shared.load(item, source: source, imageOrientation: .landscape)
                    images = EmbyFeaturedArtwork(poster: poster, logo: nil)
                } else {
                    images = await MediaThumbnailLoader.shared.featuredArtwork(for: item, source: source)
                }
                guard !Task.isCancelled else { return }
                // Keep already-visible artwork if the refresh failed.
                loadedArtwork = EmbyFeaturedArtwork(poster: images.poster ?? initialHeroArtwork?.poster,
                                                     logo: images.logo ?? initialHeroArtwork?.logo)
                loadedArtworkID = item.id
            }
    }

    private var bottomBlur: some View {
        let blur = layout.carouselBlur
        let solidHeight = size.height * blur.heightFraction
        let fadeHeight = min(blur.fadeHeight, max(0, size.height - solidHeight))
        let totalHeight = solidHeight + fadeHeight
        let fadeEnd = totalHeight > 0 ? fadeHeight / totalHeight : 0
        let strength = blur.strength
        let tint = colorScheme == .dark ? Color.black : Color.white
        let tintOpacity = (colorScheme == .dark ? 0.18 : 0.14) * strength / 0.55

        return Rectangle()
            .fill(.regularMaterial)
            .opacity(strength)
            .overlay(tint.opacity(tintOpacity))
            .mask {
                if fadeEnd > 0 {
                    LinearGradient(stops: blurMaskStops(fadeEnd: fadeEnd), startPoint: .top, endPoint: .bottom)
                } else {
                    Rectangle()
                }
            }
            .frame(height: totalHeight)
            .allowsHitTesting(false)
    }

    private func blurMaskStops(fadeEnd: CGFloat) -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = [
            .init(color: .clear, location: 0),
            .init(color: .black.opacity(0.15625), location: fadeEnd * 0.25),
            .init(color: .black.opacity(0.5), location: fadeEnd * 0.5),
            .init(color: .black.opacity(0.84375), location: fadeEnd * 0.75),
            .init(color: .black, location: fadeEnd)
        ]
        if fadeEnd < 1 { stops.append(.init(color: .black, location: 1)) }
        return stops
    }

    private var firstLine: String {
        let kind: String
        switch item.embyItemType {
        case "Series": kind = VesperLocalization.string("剧集")
        case "Movie": kind = VesperLocalization.string("电影")
        default: kind = VesperLocalization.string("视频")
        }
        let genres = (item.embyPresentation?.genres ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return ([kind] + genres.prefix(3)).joined(separator: " · ")
    }

    private var secondLine: String {
        let metadata = item.embyPresentation
        let year = item.subtitle ?? metadata?.premiereDate.map {
            String(Calendar(identifier: .gregorian).component(.year, from: $0))
        }
        let status: String?
        switch metadata?.status {
        case "Continuing": status = VesperLocalization.string("连载中")
        case "Ended": status = VesperLocalization.string("已完结")
        case "Upcoming": status = VesperLocalization.string("即将播出")
        default: status = metadata?.status
        }
        let score = metadata?.communityRating.flatMap { rating -> String? in
            guard rating > 0 else { return nil }
            return String(format: "%.1f", rating)
        }
        return [year, status, score].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct EmbySeriesPosterCard: View {
    let source: MediaSource
    let item: MediaItem
    @ObservedObject var playback: PlaybackSession
    let width: CGFloat
    let posterHeight: CGFloat
    let preloadedData: Data?
    let artworkIsPrepared: Bool
    let open: () -> Void

    @State private var episodes: [EmbyEpisode] = []
    private var played: Bool { playback.effectivePlayed(for: item) }
    private var firstEpisode: EmbyEpisode? { episodes.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: open) {
                MediaThumbnail(source: source, item: item, aspectRatio: width / posterHeight,
                               imageOrientation: .portrait,
                               fixedHeight: posterHeight, preloadedData: preloadedData,
                               artworkIsPrepared: artworkIsPrepared)
                    .frame(width: width, height: posterHeight)
                    .mediaArtworkBorder(cornerRadius: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: item.title))

            Text(verbatim: item.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2, reservesSpace: true)
            Text(verbatim: categoryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    guard let firstEpisode else { return }
                    playback.play(firstEpisode.item, in: source, queue: episodes.map(\.item))
                } label: {
                    Label(startLabel, systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(firstEpisode == nil)
                .accessibilityLabel(Text(verbatim: startLabel))

                Button {
                    playback.setPlayed(!played, for: item, source: source)
                } label: {
                    Image(systemName: played ? "checkmark" : "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .symbolEffect(.drawOn, isActive: played)
                .accessibilityLabel(played ? "标记为未观看" : "标记为已观看")
                Spacer(minLength: 0)
            }

            Text(verbatim: item.embyPresentation?.overview ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)

            factsLine
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .task(id: item.id) {
            episodes = (try? await EmbyRepository.shared.seriesEpisodes(for: item, source: source, limit: 1)) ?? []
        }
    }

    private var categoryLine: String {
        ([VesperLocalization.string("剧集")] + (item.embyPresentation?.genres ?? []).prefix(3))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " · ")
    }

    private var startLabel: String {
        guard let episode = firstEpisode else { return VesperLocalization.string("开始播放") }
        let number = String(format: "%02d", episode.number ?? 0)
        if (item.embyPresentation?.seasonCount ?? Set(episodes.map(\.season)).count) <= 1 {
            return VesperLocalization.localized("开始播放 E\(number)")
        }
        return VesperLocalization.localized("开始播放 S\(String(format: "%02d", episode.season))E\(number)")
    }

    @ViewBuilder
    private var factsLine: some View {
        let presentation = item.embyPresentation
        HStack(spacing: 5) {
            if let year = item.subtitle ?? presentation?.premiereDate.map({ String(Calendar(identifier: .gregorian).component(.year, from: $0)) }) {
                Text(verbatim: year)
            }
            if let status = presentation?.status {
                Text(verbatim: status == "Continuing" ? "连载中" : status == "Ended" ? "已完结" : status)
            }
            if let rating = presentation?.communityRating, rating > 0 {
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
            }
            if let classification = presentation?.rating, !classification.isEmpty {
                Label(classification, systemImage: "rectangle.badge.checkmark")
            }
            if let studios = presentation?.studios, !studios.isEmpty {
                Label(studios.joined(separator: "、"), systemImage: "building.2")
            }
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.65)
    }
}

private struct EmbyFeaturedPageControl: UIViewRepresentable {
    let count: Int
    let current: Int
    let onChange: (Int) -> Void

    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.backgroundStyle = .minimal
        control.allowsContinuousInteraction = false
        control.addTarget(context.coordinator, action: #selector(Coordinator.pageChanged(_:)), for: .valueChanged)
        control.currentPageIndicatorTintColor = .white
        control.pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.65)
        control.preferredCurrentPageIndicatorImage = UIImage(
            systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9)
        )
        return control
    }

    func updateUIView(_ control: UIPageControl, context: Context) {
        context.coordinator.onChange = onChange
        control.numberOfPages = count
        control.currentPage = current
        for index in 0..<count {
            let distance = abs(index - current)
            let size: CGFloat = distance <= 1 ? 7 : distance == 2 ? 5 : 3
            control.setIndicatorImage(
                UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: size)),
                forPage: index
            )
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPageControl, context: Context) -> CGSize? {
        let size = uiView.size(forNumberOfPages: count)
        return CGSize(width: max(132, size.width), height: 44)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject {
        var onChange: (Int) -> Void

        init(onChange: @escaping (Int) -> Void) { self.onChange = onChange }

        @objc func pageChanged(_ control: UIPageControl) { onChange(control.currentPage) }
    }
}

private struct EmbyMediaRoute: Hashable {
    enum Origin: Hashable {
        case carousel
        case shelf(String)
        case library(String)
        case favorites
        case person(EmbyPerson)
    }

    let source: MediaSource
    let title: String
    let itemID: String
    let item: MediaItem?
    var origin: Origin? = nil
    var opensFavorites: Bool { item == nil && origin == .favorites }
    var opensLibrary: Bool { item == nil && !opensFavorites }

    static func favorites(_ source: MediaSource) -> Self {
        Self(source: source, title: VesperLocalization.string("收藏媒体"), itemID: "", item: nil, origin: .favorites)
    }

    static func library(_ source: MediaSource, id: String, title: String) -> Self {
        Self(source: source, title: title, itemID: id, item: nil)
    }

    static func detail(_ source: MediaSource, _ item: MediaItem, origin: Origin) -> Self {
        Self(source: source, title: item.title, itemID: item.id.localID, item: item, origin: origin)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source.id == rhs.source.id && lhs.itemID == rhs.itemID && lhs.opensLibrary == rhs.opensLibrary && lhs.origin == rhs.origin
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(source.id)
        hasher.combine(itemID)
        hasher.combine(opensLibrary)
        hasher.combine(origin)
    }
}

struct EmbyPersonWorksView: View {
    let source: MediaSource
    let person: EmbyPerson
    @Namespace private var artworkZoom
    @State private var openedWork: EmbyMediaRoute?

    var body: some View {
        EmbySeriesBrowserView(source: source, groupTitle: person.name, parentID: nil, scope: .person(person),
                              artworkZoom: artworkZoom, openDetail: { openedWork = $0 })
            .navigationDestination(item: $openedWork) { route in
                workDestination(route)
            }
    }

    // A series can open another person’s works page.
    private func workDestination(_ route: EmbyMediaRoute) -> AnyView {
        guard let item = route.item else { return AnyView(EmptyView()) }
        if item.isEmbySeries {
            return AnyView(
                EmbyMediaDetailView(source: source, series: item)
                    .navigationTransition(.zoom(sourceID: route, in: artworkZoom))
            )
        }
        return AnyView(EmbyMediaDetailView(source: source, series: item))
    }
}

private enum EmbyBrowserLayout: String, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
    var title: LocalizedStringKey { self == .grid ? "网格显示" : "列表显示" }
    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

private enum EmbyBrowserSort: String, CaseIterable, Identifiable {
    case name = "SortName", added = "DateCreated", released = "PremiereDate", year = "ProductionYear"
    case rating = "CommunityRating", lastPlayed = "DatePlayed", runtime = "Runtime"
    case resolution = "Resolution", size = "Size"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .name: "textformat.abc"
        case .added: "calendar.badge.plus"
        case .released: "calendar"
        case .year: "calendar"
        case .rating: "star"
        case .lastPlayed: "clock.arrow.circlepath"
        case .runtime: "timer"
        case .resolution: "tv"
        case .size: "internaldrive"
        }
    }
    var title: LocalizedStringKey {
        switch self {
        case .name: "名称"
        case .added: "添加日期"
        case .released: "发行日期"
        case .year: "年份"
        case .rating: "社区评分"
        case .lastPlayed: "最近播放"
        case .runtime: "时长"
        case .resolution: "分辨率"
        case .size: "文件大小"
        }
    }
}

private struct EmbySeriesBrowserView: View {
    let source: MediaSource
    let groupTitle: String
    let parentID: String?
    let scope: EmbyBrowseScope
    let artworkZoom: Namespace.ID
    let openDetail: (EmbyMediaRoute) -> Void
    @EnvironmentObject private var playback: PlaybackSession
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @State private var items: [MediaItem] = []
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var didLoadFirstPage = false
    @State private var nextOffset = 0
    @State private var errorMessage: String?
    @State private var loadGeneration = UUID()
    @AppStorage("emby.browser.layout") private var displayLayout: EmbyBrowserLayout = .list
    @AppStorage("emby.browser.sort") private var sortField: EmbyBrowserSort = .added
    @AppStorage("emby.browser.ascending") private var ascending = false

    private var sortIdentity: String { "\(sortField.rawValue):\(ascending)" }

    private let pageSize = 21
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: CGFloat(layout[.itemSpacing])), count: 3)
    }

    var body: some View {
        ScrollView {
            Group {
                if displayLayout == .grid {
                    LazyVGrid(columns: columns, spacing: CGFloat(layout[.itemVerticalPadding]) * 2) {
                        browserItems
                    }
                } else {
                    LazyVStack(spacing: 16) {
                        browserItems
                    }
                }
            }
            .padding(.horizontal, CGFloat(layout[.endPadding]))
            .padding(.vertical, CGFloat(layout[.itemVerticalPadding] + layout[.scrollPadding]))
            if isLoading && didLoadFirstPage { ProgressView().padding() }
            if reachedEnd && items.isEmpty {
                Text(emptyMessage).foregroundStyle(.secondary).padding()
            }
            if let errorMessage {
                Button("重试") { Task { await loadPage() } }
                    .padding()
                Text(verbatim: errorMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .id(sortIdentity)
        .background(VesperTheme.background.ignoresSafeArea())
        .overlay {
            if items.isEmpty && !didLoadFirstPage && errorMessage == nil { VesperPageLoadingOverlay() }
        }
        .scrollIndicators(.hidden)
        .navigationTitle(groupTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("布局方式", selection: $displayLayout) {
                        ForEach(EmbyBrowserLayout.allCases) { value in
                            Label(value.title, systemImage: value.symbol).tag(value)
                        }
                    }
                    Picker("排序方式", selection: $ascending) {
                        Label("正序", systemImage: "arrow.up").tag(true)
                        Label("倒序", systemImage: "arrow.down").tag(false)
                    }
                    Picker("排序依据", selection: $sortField) {
                        ForEach(EmbyBrowserSort.allCases) { value in
                            Label(value.title, systemImage: value.symbol).tag(value)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("布局与排序")
            }
        }
        .task(id: sortIdentity) {
            loadGeneration = UUID()
            let token = loadGeneration
            let key = cacheKey
            items = []
            isLoading = false
            reachedEnd = false
            didLoadFirstPage = false
            nextOffset = 0
            errorMessage = nil
            let cached = await AppCacheStore.shared.items(scope: cacheScope, key: key)
            guard !Task.isCancelled, loadGeneration == token else { return }
            if let cached, items.isEmpty { items = cached }
            await loadPage()
        }
    }

    private var browserItems: some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            let route = EmbyMediaRoute.detail(source, item, origin: detailOrigin)
            Button { openDetail(route) } label: {
                if displayLayout == .grid {
                    MediaThumbnail(source: source, item: item, imageOrientation: .portrait,
                                   fixedHeight: layout.thumbnailHeight)
                        .mediaArtworkBorder()
                        .matchedTransitionSource(id: route, in: artworkZoom)
                } else {
                    libraryRow(item, route: route)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: item.title))
            .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback,
                                         showsEmbyFacts: true, openEmbyDetails: { openDetail(route) }) { EmptyView() })
            .onAppear {
                if didLoadFirstPage, index >= items.count - 5, errorMessage == nil {
                    Task { await loadPage() }
                }
            }
        }
    }

    private func libraryRow(_ item: MediaItem, route: EmbyMediaRoute) -> some View {
        let rowHeight = CGFloat(layout[.browserListRowHeight])
        let imageTop = CGFloat(layout[.browserListImageTop])
        let imageLeading = CGFloat(layout[.browserListImageLeading])
        let imageBottom = CGFloat(layout[.browserListImageBottom])
        let imageTrailing = CGFloat(layout[.browserListImageTrailing])
        let imageHeight = max(24, rowHeight - imageTop - imageBottom)
        let imageWidth = imageHeight * 2 / 3
        let kind = item.embyItemType == "Movie" ? "电影" : "剧集"
        let genres = item.embyPresentation?.genres.prefix(3).joined(separator: " · ")
        let year = item.subtitle ?? item.embyPresentation?.premiereDate.map {
            String(Calendar.current.component(.year, from: $0))
        } ?? "—"
        let rating = item.embyPresentation?.communityRating.map { String(format: "%.1f", $0) }
        let details = [kind, genres].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let yearAndRating = [year, rating.map { "★ \($0)" }].compactMap { $0 }.joined(separator: " · ")

        return HStack(spacing: 12) {
            ZStack {
                MediaThumbnail(source: source, item: item, imageOrientation: .portrait, fixedHeight: imageHeight)
                    .frame(width: imageWidth, height: imageHeight)
                    .mediaArtworkBorder()
                    .matchedTransitionSource(id: route, in: artworkZoom)
                    .padding(.top, imageTop)
                    .padding(.leading, imageLeading)
                    .padding(.bottom, imageBottom)
                    .padding(.trailing, imageTrailing)
            }
            .frame(width: imageWidth + imageLeading + imageTrailing, height: rowHeight)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: yearAndRating)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var detailOrigin: EmbyMediaRoute.Origin {
        if case .person(let person) = scope { return .person(person) }
        return parentID.map { .library($0) } ?? .favorites
    }

    private var emptyMessage: LocalizedStringKey {
        switch scope {
        case .favorites: "暂无收藏媒体"
        case .person: "暂无作品"
        default: "暂无媒体"
        }
    }

    private var cacheScope: String { AppCacheStore.scope(for: source) }
    private var cacheKey: String { "browser:\(scope.cacheKey):\(parentID ?? ""):\(sortIdentity)" }

    private func loadPage() async {
        guard !isLoading, !reachedEnd else { return }
        let token = loadGeneration
        let key = cacheKey
        let field = sortField.rawValue
        let order = ascending ? "Ascending" : "Descending"
        isLoading = true
        errorMessage = nil
        defer { if loadGeneration == token { isLoading = false } }
        do {
            let generation = await AppCacheStore.shared.libraryGeneration
            let page = try await EmbyRepository.shared.items(for: source, parentID: parentID,
                                                             startIndex: nextOffset, limit: pageSize,
                                                             sortBy: field, sortOrder: order,
                                                             scope: scope)
            try Task.checkCancellation()
            guard loadGeneration == token else { return }
            if !didLoadFirstPage { items = [] }
            var seen = Set(items.map(\.id))
            items.append(contentsOf: page.filter { seen.insert($0.id).inserted })
            nextOffset += page.count
            reachedEnd = page.count < pageSize
            didLoadFirstPage = true
            await AppCacheStore.shared.save(items, scope: cacheScope, key: key, generation: generation)
        } catch {
            if !Task.isCancelled, loadGeneration == token { errorMessage = error.localizedDescription }
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
                .foregroundStyle(Color(uiColor: .label))
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

// Carousel pans should not dim artwork while a button is tracking the touch.
private struct EmbyCarouselButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
