import SwiftUI
import UIKit
import Network

#if DEBUG
import UIKit.UIGestureRecognizerSubclass
#endif

@MainActor
final class MediaLayoutSettings: ObservableObject {
    static let shared = MediaLayoutSettings()

    enum Metric: String, CaseIterable {
        case thumbnailHeight, groupSpacing, titlePadding, scrollPadding
        case itemWidth, itemHeight, itemVerticalPadding, itemSpacing, endPadding, episodeCardWidth, episodeCardHeight
        case browserListTop, browserListLeading, browserListBottom, browserListTrailing
        case browserListRowHeight, browserListImageTop, browserListImageLeading, browserListImageBottom, browserListImageTrailing
        case sourceListRowHeight, sourceListIconTop, sourceListIconLeading, sourceListIconBottom, sourceListIconTrailing

        case mediaHeaderHeight, mediaGlassStrength, mediaGlassTint, mediaContentBlur
        case mediaGlassBorderWidth, mediaGlassBorderBlur, mediaGlassBorderOpacity
        case mediaContentOpacityCurve, mediaContentBlurCurve
        case mediaSnapThreshold, mediaSnapCollapsedThreshold, mediaSnapConflict, mediaSnapDuration, mediaSnapCurve
        case mediaEdgeTopStrength, mediaEdgeTopMaxStrength, mediaEdgeHeightCurve, mediaEdgeBottomStrength, mediaEdgeTint, mediaEdgeCurve

        case carouselBlurHeight, carouselBlurFadeHeight, carouselBlurStrength, carouselBlurTint

        var usesPercent: Bool {
            switch self {
            case .mediaGlassStrength, .mediaGlassTint, .mediaGlassBorderOpacity, .mediaEdgeTopStrength, .mediaEdgeTopMaxStrength, .mediaEdgeBottomStrength, .mediaEdgeTint, .carouselBlurHeight, .carouselBlurStrength, .carouselBlurTint: true
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
            case .browserListTop: 0
            case .browserListBottom: 12
            case .browserListLeading, .browserListTrailing: 20
            case .browserListRowHeight: 80
            case .browserListImageTop, .browserListImageLeading, .browserListImageBottom, .browserListImageTrailing: 4
            case .sourceListRowHeight: 104
            case .sourceListIconTop, .sourceListIconLeading, .sourceListIconBottom, .sourceListIconTrailing: 8
            case .mediaHeaderHeight: 54
            case .mediaGlassStrength: 5
            case .mediaGlassTint: 50
            case .mediaGlassBorderWidth: 10
            case .mediaGlassBorderBlur: 0
            case .mediaGlassBorderOpacity: 15
            case .mediaContentBlur: 3
            case .mediaContentOpacityCurve, .mediaContentBlurCurve: 2
            case .mediaSnapThreshold, .mediaSnapCollapsedThreshold: 70
            case .mediaSnapConflict: 0
            case .mediaSnapDuration: 300
            case .mediaSnapCurve: 3
            case .mediaEdgeTopStrength: 5
            case .mediaEdgeTopMaxStrength: 70
            case .mediaEdgeBottomStrength: 0
            case .mediaEdgeTint: 50
            case .mediaEdgeCurve: 1
            case .mediaEdgeHeightCurve: 3
            case .carouselBlurHeight: 30
            case .carouselBlurFadeHeight: 110
            case .carouselBlurStrength: 60
            case .carouselBlurTint: 14
            }
        }

        var range: ClosedRange<Int> {
            switch self {
            case .thumbnailHeight: 0...600
            case .itemWidth, .itemHeight: 24...480
            case .browserListRowHeight: 60...320
            case .browserListImageTop, .browserListImageLeading, .browserListImageBottom, .browserListImageTrailing: 0...60
            case .sourceListRowHeight: 64...240
            case .sourceListIconTop, .sourceListIconLeading, .sourceListIconBottom, .sourceListIconTrailing: 0...60
            case .episodeCardWidth, .episodeCardHeight: 120...1200
            case .mediaHeaderHeight: 30...120
            case .mediaGlassStrength, .mediaGlassTint, .mediaGlassBorderOpacity, .mediaEdgeTopStrength, .mediaEdgeTopMaxStrength, .mediaEdgeBottomStrength, .mediaEdgeTint, .carouselBlurHeight, .carouselBlurStrength, .carouselBlurTint: 0...100
            case .mediaContentOpacityCurve, .mediaContentBlurCurve, .mediaEdgeCurve, .mediaEdgeHeightCurve: 0...4
            case .mediaSnapThreshold, .mediaSnapCollapsedThreshold: 5...95
            case .mediaSnapConflict: 0...1
            case .mediaSnapDuration: 100...1000
            case .mediaSnapCurve: 0...4
            case .mediaContentBlur: 0...40
            case .mediaGlassBorderWidth: 0...40
            case .mediaGlassBorderBlur: 0...10
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

    // Store one integer tick per 0.05 pt.
    var mediaGlassBorderWidth: CGFloat { CGFloat(self[.mediaGlassBorderWidth]) / 20 }

    var thumbnailHeight: CGFloat? {
        let value = self[.thumbnailHeight]
        return value == 0 ? nil : CGFloat(value)
    }

    var episodeCardWidth: CGFloat { CGFloat(self[.episodeCardWidth]) }
    var episodeCardHeight: CGFloat { CGFloat(self[.episodeCardHeight]) }

    var carouselBlur: CarouselPosterBlur {
        CarouselPosterBlur(heightFraction: CGFloat(self[.carouselBlurHeight]) / 100,
                           fadeHeight: CGFloat(self[.carouselBlurFadeHeight]),
                           strength: Double(self[.carouselBlurStrength]) / 100,
                           tintOpacity: Double(self[.carouselBlurTint]) / 100)
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
                               path: $path,
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
            if route.opensLibrary {
                let destination = EmbyLibraryDestination(libraryRoute: route)
                #if DEBUG
                if route.origin == .libraryCardZoom {
                    destination.navigationTransition(.zoom(sourceID: route, in: artworkZoom))
                } else {
                    destination
                }
                #else
                destination
                #endif
            } else if route.opensFavorites {
                EmbySeriesBrowserView(source: route.source, groupTitle: route.title,
                                      parentID: nil, scope: .favorites,
                                      artworkZoom: artworkZoom, openDetail: { path.append($0) })
            } else if let item = route.item {
                if route.origin == .carousel {
                    let detail = MediaDetailView(source: route.source, series: item,
                                                      startsWithCarouselInformationHidden: true,
                                                      initialHeroArtwork: library.embyHome?.featuredArtwork?[item.id])
                        .background {
                            CarouselDetailCrossfade.ReturnObserver(transition: carouselCrossfade,
                                                                   reduceMotion: reduceMotion)
                        }
                    detail
                } else {
                    MediaDetailView(source: route.source, series: item)
                        .navigationTransition(.zoom(sourceID: route, in: artworkZoom))
                }
            }
        }
        .navigationDestination(for: LocalDirectoryRoute.self) { route in
            if let source = library.selectedSource, source.kind == .local {
                LocalFilesView(source: source, directory: route.path, path: $path,
                               sourceMenu: { busy, createFolder in
                    mediaSourceMenu(localBusy: busy, createLocalFolder: createFolder)
                })
            }
        }
    }

    private var featured: [MediaItem] {
        guard library.selectedSource?.kind == .emby,
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
        let showsFeaturedRegion = library.selectedSource?.kind == .emby
        let title: LocalizedStringKey = library.selectedSource.map { LocalizedStringKey("\($0.name)") } ?? "媒体"
        return VesperRootScrollView(title: title, extendsContentUnderHeader: showsFeaturedRegion,
                                   showsLoading: isLoadingMedia, usesMediaScrollEdges: true,
                                   scrollPosition: $mediaScrollPosition,
                                   onVerticalOffsetChange: updateMediaScrollOffset,
                                   onVerticalScrollPhaseChange: updateMediaScrollPhase,
                                   onTopPullChange: expandEmbyShortcuts(forTopPull:)) {
            VStack(alignment: .leading, spacing: 20) {
                if let source = library.selectedSource, showsFeaturedRegion {
                    EmbyFeaturedCarousel(source: source, items: featured,
                                         featuredArtwork: library.embyHome?.featuredArtwork,
                                         isMediaRoot: path.isEmpty && pendingCarouselRoute == nil,
                                         hidesInformation: hidesCarouselInformation,
                                         openDetail: openCarouselDetail)
                }
                if library.selectedSource == nil {
                    VesperCenteredEmptyContent(message: "未选择媒体来源", symbol: AppSection.media.symbol)
                } else if library.selectedSource?.kind == .emby, library.isLoadingEmbyHome, library.embyHome == nil {
                    EmptyView()
                } else if library.selectedSource?.kind == .emby, library.embyHome != nil {
                    if let source = library.selectedSource {
                        recentPlaybackGroup(source: source)
                    }
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
                                    if let source = library.selectedSource {
                                        Button {
                                            playback.play(item, in: source, queue: items)
                                        } label: {
                                            MediaThumbnail(source: source, item: item, playback: playback,
                                                           imageOrientation: .portrait,
                                                           fixedHeight: layout.thumbnailHeight)
                                                .modifier(DeviceMediaCardBackground(enabled: source.kind == .local || source.kind == .photos))
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback) { EmptyView() })
                                        .accessibilityLabel(Text(verbatim: item.title))
                                    }
                                }
                            }
                            .padding(.horizontal, CGFloat(layout[.endPadding]))
                            .padding(.vertical, CGFloat(layout[.itemVerticalPadding] + layout[.scrollPadding]))
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
                                Label("无法加载来源", systemImage: "exclamationmark.triangle")
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
            if !library.visibleSources.isEmpty {
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
    private func recentPlaybackGroup(source: MediaSource) -> some View {
        let entries = playback.history
            .filter { $0.source.id == source.id && $0.hiddenFromHistory != true }
            .sorted { $0.watchedAt > $1.watchedAt }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("继续播放")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, CGFloat(layout[.endPadding]))
                    .padding(.vertical, CGFloat(layout[.titlePadding]))
                ScrollView(.horizontal) {
                    LazyHStack(spacing: CGFloat(layout[.itemSpacing])) {
                        ForEach(entries.prefix(20)) { entry in
                            RecentEmbyPlaybackCard(source: source, entry: entry, artworkZoom: artworkZoom,
                                                   open: { route in
                                                       path.append(route)
                                                   },
                                                   clear: { item in
                                                       Task { try? await playback.clearProgress(for: item, source: source) }
                                                   },
                                                   setPlayed: { item, played in
                                                       playback.setPlayed(played, for: item, source: source)
                                                   })
                        }
                    }
                    .padding(.vertical, CGFloat(layout[.itemVerticalPadding]))
                }
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, CGFloat(layout[.endPadding]), for: .scrollContent)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .never, anchor: .leading))
                .id(library.refreshGeneration)
                .padding(.vertical, CGFloat(layout[.scrollPadding]))
            }
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
                                            groupCard(item, in: group, source: source)
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
                            .id(library.refreshGeneration)
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
    private func groupCard(_ item: MediaItem, in group: EmbyMediaGroup, source: MediaSource) -> some View {
        let size = groupCardSize(group)
        if group.id == EmbyMediaGroup.librariesID {
            #if DEBUG
            let route = EmbyMediaRoute.library(source, id: item.id.localID, title: item.title, origin: .libraryCardZoom)
            #else
            let route = EmbyMediaRoute.library(source, id: item.id.localID, title: item.title)
            #endif
            NavigationLink(value: route) {
                MediaThumbnail(source: source, item: item, aspectRatio: size.width / size.height,
                               imageOrientation: .landscape)
                    .frame(width: size.width, height: size.height)
                    .mediaArtworkBorder()
                    #if DEBUG
                    .matchedTransitionSource(id: route, in: artworkZoom)
                    #endif
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
                                       cacheOnly: true)
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
                               aspectRatio: size.width / size.height, imageOrientation: .portrait)
                    .frame(width: size.width, height: size.height)
                    .mediaArtworkBorder()
                    .matchedTransitionSource(id: route, in: artworkZoom)
            }
            .buttonStyle(.plain)
            .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback,
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
        let width = CGFloat(layout[.itemWidth])
        let height = CGFloat(layout[.itemHeight])
        if isLibraries {
            let libraryWidth: CGFloat = 246
            return CGSize(width: libraryWidth, height: libraryWidth * 9 / 16)
        }
        return CGSize(width: width, height: height)
    }

    private var embyHomeSource: MediaSource? {
        guard let source = library.selectedSource, source.kind == .emby else { return nil }
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
        let isExpanded = (source != nil || isLocal) && showsEmbyShortcuts
        let iconSize: CGFloat = 20

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
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isExpanded)
            }
            sourceMenuButton(localBusy: localBusy, createLocalFolder: createLocalFolder, iconSize: iconSize)
                // Keep the trailing source selector stationary; only the
                // auxiliary controls and glass capsule should animate.
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
        // A single native glass capsule becomes a circle at its collapsed width.
        .glassEffect(.regular.interactive(), in: .capsule)
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
                if inMenu { menuSymbol("arrow.clockwise") }
                else { Image(systemName: "arrow.clockwise") }
            }
        }
        .disabled(library.isLoadingEmbyHome)
    }

    private func favoritesButton(_ source: MediaSource, inMenu: Bool = true) -> some View {
        Button { path.append(EmbyMediaRoute.favorites(source)) } label: {
            Label { Text("收藏媒体") } icon: {
                if inMenu { menuSymbol("heart") }
                else { Image(systemName: "heart") }
            }
        }
    }

    private func sourceSymbol(_ source: MediaSource?) -> String {
        switch source?.kind {
        case .photos: "play.rectangle.on.rectangle"
        case .local: "folder"
        case .emby: "server.rack"
        case nil: "externaldrive"
        }
    }

    // Bake the theme color into original-rendering images so native menus retain it.
    private func menuSymbol(_ name: String, visible: Bool = true) -> Image {
        let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        let tint = visible ? UIColor(VesperTheme.accent(accent)) : UIColor.clear
        let icon = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
        return icon.map { Image(uiImage: $0).renderingMode(.original) } ?? Image(systemName: name)
    }

    private func sourceMenuIcon(_ source: MediaSource, size: CGFloat, inMenu: Bool = true) -> Image {
        let configuredIcon = source.emby?.iconData.flatMap { UIImage(data: $0) }
        let image = configuredIcon ?? UIImage(named: "EmbyLogo")
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return inMenu ? menuSymbol(sourceSymbol(source)) : Image(systemName: sourceSymbol(source))
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
        return Image(uiImage: icon).renderingMode(.original)
    }

    private func selectSource(_ source: MediaSource) {
        guard source.id != library.selectedID else { return }
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

    private func routeMenuItem(_ source: MediaSource, address: String, title: String) -> some View {
        let isSelected = EmbyRouteOptions.key(source.emby?.serverAddress ?? "")
            == EmbyRouteOptions.key(address)

        return Button {
            library.switchEmbyRoute(source.id, address: address)
        } label: {
            Label { Text(verbatim: title) } icon: {
                menuSymbol("checkmark", visible: isSelected)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                ForEach(library.visibleSources) { source in
                    Button {
                        selectSource(source)
                    } label: {
                        Label {
                            Text(verbatim: source.kind == .local ? VesperLocalization.string("本地视频")
                                 : source.kind == .photos ? VesperLocalization.string("相册视频") : source.name)
                        } icon: {
                            if source.kind == .emby {
                                sourceMenuIcon(source, size: 22)
                            } else {
                                menuSymbol(sourceSymbol(source))
                            }
                        }
                    }
                    .accessibilityAddTraits(source.id == library.selectedID ? .isSelected : [])
                }
            }
            if let source = library.selectedSource, let configuration = source.emby,
               !configuration.backupRoutes.isEmpty {
                Section {
                    Menu {
                        routeMenuItem(source, address: configuration.primaryRoute,
                                      title: VesperLocalization.localized("主线路"))
                        ForEach(Array(configuration.backupRoutes.enumerated()), id: \.element) { index, address in
                            let title = configuration.alternateRouteNames?[EmbyRouteOptions.key(address)]
                                ?? VesperLocalization.localized("备用线路 \(index + 1)")
                            routeMenuItem(source, address: address, title: title)
                        }
                    } label: {
                        Label { Text("切换线路") } icon: { menuSymbol("network") }
                    }
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



struct EmbyMediaRoute: Hashable {
    enum Origin: Hashable {
        case carousel
        case shelf(String)
        case library(String)
        #if DEBUG
        case libraryCardZoom
        #endif
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

    static func library(_ source: MediaSource, id: String, title: String, origin: Origin? = nil) -> Self {
        Self(source: source, title: title, itemID: id, item: nil, origin: origin)
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

private struct EmbyLibraryDestination: View {
    let libraryRoute: EmbyMediaRoute
    @Namespace private var artworkZoom
    @State private var openedDetail: EmbyMediaRoute?

    var body: some View {
        EmbySeriesBrowserView(source: libraryRoute.source, groupTitle: libraryRoute.title,
                              parentID: libraryRoute.itemID, scope: .titles,
                              artworkZoom: artworkZoom, openDetail: { openedDetail = $0 })
            #if DEBUG
            .background(EmbyNavigationTouchDiagnostics(
                page: libraryRoute.origin == .libraryCardZoom ? "library-zoom" : "library-default"
            ).allowsHitTesting(false))
            #endif
            .navigationDestination(item: $openedDetail) { route in
                if let item = route.item {
                    MediaDetailView(source: route.source, series: item)
                        .navigationTransition(.zoom(sourceID: route, in: artworkZoom))
                }
            }
    }
}

#if DEBUG
struct EmbyNavigationTouchDiagnostics: UIViewControllerRepresentable {
    let page: String

    func makeUIViewController(context: Context) -> Reporter {
        let controller = Reporter()
        controller.page = page
        return controller
    }

    func updateUIViewController(_ controller: Reporter, context: Context) {}

    static func dismantleUIViewController(_ controller: Reporter, coordinator: ()) {
        controller.detach()
    }

    final class Reporter: UIViewController {
        private let probe: TouchProbe = {
            let probe = TouchProbe(target: nil, action: nil)
            probe.cancelsTouchesInView = false
            probe.delaysTouchesBegan = false
            probe.delaysTouchesEnded = false
            return probe
        }()
        var page = ""
        private let pageID = String(UUID().uuidString.prefix(8))
        private let formatter = ISO8601DateFormatter()
        private weak var observedPage: UIViewController?
        private weak var navigation: UINavigationController?
        private var startedAt: TimeInterval = 0
        private var appearance = 0

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            appearance += 1
            startedAt = ProcessInfo.processInfo.systemUptime
            attach()
            log("willAppear \(navigationState())")
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
            log("didAppear \(navigationState())")
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            log("didDisappear \(navigationState())")
            startedAt = 0
        }

        private func attach() {
            guard let window = view.window else { return }
            navigation = navigationController ?? navigation
            var ancestor = parent
            while let controller = ancestor {
                if navigation?.viewControllers.contains(where: { $0 === controller }) == true {
                    observedPage = controller
                    break
                }
                ancestor = controller.parent
            }
            guard probe.view !== window else { return }
            detach()
            probe.report = { [weak self] event, hitView, point in
                self?.report(event, hitView: hitView, point: point)
            }
            window.addGestureRecognizer(probe)
        }

        func detach() {
            probe.view?.removeGestureRecognizer(probe)
            probe.report = nil
        }

        private func report(_ event: String, hitView: UIView?, point: CGPoint) {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            guard elapsed < 8, let window = probe.view else { return }
            let edge = point.x < 24 ? "left" : point.x > window.bounds.width - 24 ? "right" : "interior"
            var ancestors: [String] = []
            var scroll: UIScrollView?
            var current = hitView
            while let view = current {
                if scroll == nil { scroll = view as? UIScrollView }
                ancestors.append(String(describing: type(of: view)))
                current = view.superview
            }
            let inPage = (observedPage?.viewIfLoaded).map { hitView?.isDescendant(of: $0) == true } ?? false
            log("\(event) zone=\(edge) inPage=\(inPage) scroll=\(describe(scroll?.panGestureRecognizer)) \(navigationState()) hit=\(ancestors.prefix(12).joined(separator: ">"))")
        }

        private func navigationState() -> String {
            guard let navigation else { return "navigation=unavailable" }
            let coordinator = navigation.transitionCoordinator
            let phase = coordinator.map { $0.isInteractive ? "interactive" : "animating" } ?? "idle"
            return "depth=\(navigation.viewControllers.count) transition=\(phase) edge=\(describe(navigation.interactivePopGestureRecognizer)) content=\(describe(navigation.interactiveContentPopGestureRecognizer))"
        }

        private func describe(_ recognizer: UIGestureRecognizer?) -> String {
            guard let recognizer else { return "-" }
            return "\(recognizer.isEnabled ? "on" : "off")/\(recognizer.state)"
        }

        private func log(_ message: String) {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            AppLog.runtimeEntries.append("\(formatter.string(from: Date())) [MediaTouch] page=\(page) id=\(pageID) appearance=\(appearance) t=\(elapsed)ms \(message)")
        }
    }

    private final class TouchProbe: UIGestureRecognizer {
        var report: ((String, UIView?, CGPoint) -> Void)?
        private weak var trackedTouch: UITouch?
        private var start = CGPoint.zero
        private var reportedDrag = false

        // This observer stays possible until it fails, so it never claims the touch.
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard trackedTouch == nil, let touch = touches.first else { return }
            trackedTouch = touch
            start = touch.location(in: view)
            report?("down", touch.view, start)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch = trackedTouch, touches.contains(touch), !reportedDrag else { return }
            let point = touch.location(in: view)
            let dx = point.x - start.x
            let dy = point.y - start.y
            guard max(abs(dx), abs(dy)) >= 12 else { return }
            reportedDrag = true
            let direction = abs(dx) > abs(dy) ? "horizontal" : "vertical"
            let origin = start
            DispatchQueue.main.async { [weak self, weak hitView = touch.view] in
                self?.report?("drag \(direction)", hitView, origin)
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch = trackedTouch, touches.contains(touch) else { return }
            if reportedDrag { report?("up", touch.view, start) }
            state = .failed
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch = trackedTouch, touches.contains(touch) else { return }
            report?("cancelled", touch.view, start)
            state = .failed
        }

        override func reset() {
            super.reset()
            trackedTouch = nil
            reportedDrag = false
        }
    }
}
#endif

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
                MediaDetailView(source: source, series: item)
                    .navigationTransition(.zoom(sourceID: route, in: artworkZoom))
            )
        }
        return AnyView(MediaDetailView(source: source, series: item))
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
    @EnvironmentObject private var library: SourceLibrary
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @State private var items: [MediaItem] = []
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var didLoadFirstPage = false
    @State private var nextOffset = 0
    @State private var errorMessage: String?
    @State private var loadGeneration = UUID()
    @State private var activeQuery: String?
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
                    .padding(.horizontal, CGFloat(layout[.endPadding]))
                    .padding(.vertical, CGFloat(layout[.itemVerticalPadding] + layout[.scrollPadding]))
                } else {
                    LazyVStack(spacing: 0) {
                        browserItems
                    }
                    .padding(.top, CGFloat(layout[.browserListTop]))
                    .padding(.leading, CGFloat(layout[.browserListLeading]))
                    .padding(.bottom, CGFloat(layout[.browserListBottom]))
                    .padding(.trailing, CGFloat(layout[.browserListTrailing]))
                }
            }
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
            if items.isEmpty && !didLoadFirstPage && errorMessage == nil {
                VesperPageLoadingOverlay()
                    .allowsHitTesting(false)
            }
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
        .task(id: queryIdentity) {
            // Returning from a detail can restart this task. Keep the rows and
            // their zoom anchors mounted as long as the library query is the same.
            if activeQuery != queryIdentity {
                activeQuery = queryIdentity
                loadGeneration = UUID()
                items = []
                isLoading = false
                reachedEnd = false
                didLoadFirstPage = false
                nextOffset = 0
                errorMessage = nil
            }

            guard !didLoadFirstPage, errorMessage == nil else { return }
            let token = loadGeneration
            if items.isEmpty {
                let cached = await AppCacheStore.shared.items(scope: cacheScope, key: cacheKey)
                guard !Task.isCancelled, loadGeneration == token else { return }
                if let cached, items.isEmpty { items = cached }
            }
            guard !Task.isCancelled else { return }
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
                    MediaLibraryListRow(source: source, item: item, transition: (route, artworkZoom))
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
            if displayLayout == .list, index < items.count - 1 {
                Divider().padding(.leading, MediaLibraryListRow(source: source, item: item).dividerInset)
            }
        }
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

    private var queryIdentity: String { "\(cacheScope)|\(cacheKey)" }

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
            let page = try await library.catalog.items(for: source, parentID: parentID,
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
struct EmbyCarouselButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
