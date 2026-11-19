import SwiftUI
import UIKit

@MainActor
final class MediaLayoutSettings: ObservableObject {
    static let shared = MediaLayoutSettings()

    enum Metric: String, CaseIterable {
        case thumbnailHeight, groupSpacing, titlePadding, scrollPadding
        case itemWidth, itemHeight, itemVerticalPadding, itemSpacing, endPadding, episodeCardWidth, episodeCardHeight

        case statusBarEdgeBlur, headerBackdropBlur, headerForegroundBlur, headerAnimationMinimumDistance, headerTitleSize

        case carouselBlurHeight, carouselBlurFadeHeight, carouselBlurStrength

        var usesPercent: Bool {
            switch self {
            case .statusBarEdgeBlur, .headerBackdropBlur, .carouselBlurHeight, .carouselBlurStrength: true
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
            case .statusBarEdgeBlur: 100
            case .headerBackdropBlur: 65
            case .headerForegroundBlur: 8
            case .headerAnimationMinimumDistance: 5
            case .headerTitleSize: 34
            case .carouselBlurHeight: 40
            case .carouselBlurFadeHeight: 24
            case .carouselBlurStrength: 55
            }
        }

        var range: ClosedRange<Int> {
            switch self {
            case .thumbnailHeight: 0...600
            case .itemWidth, .itemHeight: 24...480
            case .episodeCardWidth, .episodeCardHeight: 120...1200
            case .statusBarEdgeBlur, .headerBackdropBlur, .carouselBlurHeight, .carouselBlurStrength: 0...100
            case .headerForegroundBlur: 0...40
            case .headerAnimationMinimumDistance: 1...60
            case .headerTitleSize: 18...44
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
    let scrollToTopRequest: Int
    @EnvironmentObject private var library: SourceLibrary
    @EnvironmentObject private var playback: PlaybackSession
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @AppStorage("navigation.icons") private var icons = "{}"
    @Namespace private var artworkZoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsEmbyShortcuts = false
    @State private var mediaScrollPosition = ScrollPosition(edge: .top)
    @State private var mediaScrollOffset: CGFloat = 0
    @State private var mediaScrollPhase: ScrollPhase = .idle
    @State private var pendingCarouselRoute: EmbyMediaRoute?
    @State private var carouselCrossfade = CarouselDetailCrossfade()

    var body: some View {
        Group {
            if let source = library.selectedSource, source.kind == .local {
                LocalFilesView(source: source, scrollToTopRequest: scrollToTopRequest) { mediaSourceMenu }
                    .id(source.id)
            } else {
                mediaContent
            }
        }
        .background {
            CarouselDetailCrossfade.Anchor(transition: carouselCrossfade)
                .ignoresSafeArea(.container, edges: .top)
        }
        .onChange(of: library.selectedID) { _, _ in
            showsEmbyShortcuts = false
            pendingCarouselRoute = nil
        }
        .onChange(of: scrollToTopRequest) { _, _ in
            pendingCarouselRoute = nil
            showsEmbyShortcuts = false
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.32)) {
                mediaScrollPosition.scrollTo(edge: .top)
            }
        }
        .onChange(of: path.isEmpty) { _, isEmpty in
            if !isEmpty { pendingCarouselRoute = nil }
        }
        .onDisappear { pendingCarouselRoute = nil }
        .task(id: pendingCarouselRoute) {
            guard pendingCarouselRoute != nil else { return }
            // Release the pending tap if the scroll is interrupted without reaching the top.
            do {
                try await Task.sleep(for: .seconds(1))
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
                    let detail = EmbySeriesDetailView(source: route.source, series: item,
                                                      carouselArtwork: route.carouselArtwork)
                        .background {
                            CarouselDetailCrossfade.ReturnObserver(transition: carouselCrossfade,
                                                                   reduceMotion: reduceMotion)
                        }
                        .onAppear { carouselCrossfade.revealDetail() }
                    if #available(iOS 27, *) {
                        detail.navigationTransition(.crossFade)
                    } else {
                        detail
                    }
                } else if item.isEmbySeries {
                    EmbySeriesDetailView(source: route.source, series: item)
                        .navigationTransition(.zoom(sourceID: route, in: artworkZoom))
                } else {
                    EmbyItemDetailView(source: route.source, item: item)
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
        return VesperRootScrollView(title: "媒体", extendsContentUnderHeader: showsFeaturedRegion,
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
                Button("返回", systemImage: "chevron.left") { library.navigateEmbyBack() }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            if !library.sources.isEmpty {
                mediaSourceMenu
            }
        }
        .background(VesperTheme.background.ignoresSafeArea())
        .modifier(ConditionalMediaRefresh(enabled: library.selectedSource?.kind != .emby) { [library] in
            library.reload()
        })
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
                        Text(verbatim: group.title)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
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
        .padding(.horizontal, 20)
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
                MediaThumbnail(source: source, item: item, playback: playback, aspectRatio: size.width / size.height,
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

    private func updateMediaScrollOffset(_ offset: CGFloat) {
        mediaScrollOffset = offset
        showPendingCarouselDestinationIfAtTop()
        if showsEmbyShortcuts, offset > 1, embyHomeSource != nil {
            showsEmbyShortcuts = false
        }
    }

    private func expandEmbyShortcuts(forTopPull pull: CGFloat) {
        guard pull >= 18, embyHomeSource != nil, !showsEmbyShortcuts else { return }
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
        if isMediaScrollAtRestAtTop {
            showCarouselDestination(route)
            return
        }

        pendingCarouselRoute = route
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
        showCarouselDestination(route)
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

    private var mediaSourceMenu: some View {
        let source = embyHomeSource
        let isExpanded = source != nil && showsEmbyShortcuts

        return HStack(spacing: 0) {
            if let source {
                HStack(spacing: 0) {
                    refreshButton
                        .frame(width: 44, height: 44)
                    favoritesButton(source)
                        .frame(width: 44, height: 44)
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 20, weight: .medium))
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: isExpanded ? 88 : 0, alignment: .trailing)
                .clipped()
                .opacity(isExpanded ? 1 : 0)
                .allowsHitTesting(isExpanded)
                .accessibilityHidden(!isExpanded)
            }
            sourceMenuButton
        }
        // A single native glass capsule becomes a circle at its collapsed width.
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isExpanded)
    }

    private var refreshButton: some View {
        Button("刷新页面", systemImage: "arrow.clockwise") { library.reload() }
            .disabled(library.isLoadingEmbyHome)
    }

    private func favoritesButton(_ source: MediaSource) -> some View {
        Button("收藏媒体", systemImage: "heart") { path.append(EmbyMediaRoute.favorites(source)) }
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

    private func sourceMenuIcon(_ source: MediaSource, size: CGFloat) -> Image {
        let configuredIcon = source.emby?.iconData.flatMap { UIImage(data: $0) }
        let image = configuredIcon ?? UIImage(named: "EmbyLogo")
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return Image(systemName: sourceSymbol(source))
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

    private var sourceMenuButton: some View {
        Menu {
            if let source = embyHomeSource, !showsEmbyShortcuts {
                Section { refreshButton }
                Section { favoritesButton(source) }
            }
            Section {
                ForEach(library.sources) { source in
                    Button {
                        library.select(source.id)
                    } label: {
                        Label {
                            Text(verbatim: source.name)
                        } icon: {
                            if source.kind == .emby {
                                sourceMenuIcon(source, size: 22)
                            } else {
                                Image(systemName: source.id == library.selectedID ? "checkmark" : sourceSymbol(source))
                            }
                        }
                    }
                    .accessibilityAddTraits(source.id == library.selectedID ? .isSelected : [])
                }
            }
        } label: {
            Group {
                if let source = library.selectedSource, source.kind == .emby {
                    sourceMenuIcon(source, size: 24)
                } else {
                    Image(systemName: sourceSymbol(library.selectedSource))
                        .contentTransition(.symbolEffect(.replace))
                        .font(.system(size: 17, weight: .medium))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择媒体来源")
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

        // Drop the cover even if the navigation destination never appears.
        Task { [weak self, weak cover] in
            try? await Task.sleep(for: .seconds(1))
            guard let cover, self?.pushCover === cover else { return }
            self?.revealDetail()
        }
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
                        let route = EmbyMediaRoute.detail(source, item, origin: .carousel,
                                                          carouselArtwork: .init(poster: images?.poster ?? fallback, logo: images?.logo))
                        Button { openDetail(route) } label: {
                            EmbyFeaturedPage(source: source, item: item, size: geometry.size,
                                             artwork: fallback, artworkIsPrepared: artwork != nil,
                                             featuredArtwork: images,
                                             featuredArtworkIsPrepared: images != nil,
                                             showsInformation: isCurrent && !isTransitioning,
                                             mirroredEdgeFraction: (isCurrent || isIncoming) && isTransitioning && !reduceMotion ? mirrorFraction : 0)
                        }
                        .buttonStyle(.plain)
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
    static let informationBottomInset: CGFloat = 112
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
    let showsInformation: Bool
    var seriesFooter: EmbySeriesHeroFooter? = nil
    var seriesFooterOpacity: Double = 1
    var mirroredEdgeFraction: CGFloat = 0
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedArtwork: EmbyFeaturedArtwork?
    @State private var loadedArtworkID: MediaID?

    var body: some View {
        let images = featuredArtworkIsPrepared
            ? featuredArtwork
            : loadedArtworkID == item.id ? loadedArtwork : nil
        MediaThumbnail(source: source, item: item, cornerRadius: 0, fixedHeight: size.height,
                       preloadedData: images?.poster ?? artwork,
                       artworkIsPrepared: images?.poster != nil || artworkIsPrepared,
                       mirroredEdgeFraction: mirroredEdgeFraction,
                       showsMissingArtwork: featuredArtworkIsPrepared || loadedArtwork != nil)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    bottomBlur

                    VStack(spacing: 6) {
                        Group {
                            if let logo = images?.logo, let image = UIImage(data: logo) {
                                Image(uiImage: image).resizable().scaledToFit()
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
                            Text(verbatim: firstLine)
                            if !secondLine.isEmpty { Text(verbatim: secondLine) }
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
                    .padding(.bottom, EmbyPosterLayout.informationBottomInset)
                    .frame(maxWidth: .infinity)
                    .opacity(showsInformation ? 1 : 0)
                    .animation(.easeInOut(duration: 0.16), value: showsInformation)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    if let seriesFooter {
                        seriesFooter
                            .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                            .shadow(color: (colorScheme == .dark ? Color.black : Color.white).opacity(0.65), radius: 3, y: 1)
                            .padding(.horizontal, 20)
                            .padding(.bottom, EmbyPosterLayout.seriesFooterBottomInset)
                            .opacity(seriesFooterOpacity)
                            .accessibilityHidden(seriesFooterOpacity == 0)
                            .allowsHitTesting(false)
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
                let images = await MediaThumbnailLoader.shared.featuredArtwork(for: item, source: source)
                guard !Task.isCancelled else { return }
                loadedArtwork = images
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
        case "Series": kind = String(localized: "剧集")
        case "Movie": kind = String(localized: "电影")
        default: kind = String(localized: "视频")
        }
        let genres = (item.embyPresentation?.genres ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return ([kind] + genres.prefix(3)).joined(separator: " · ")
    }

    private var secondLine: String {
        let metadata = item.embyPresentation
        let month = metadata?.premiereDate?.formatted(
            Date.FormatStyle(timeZone: TimeZone(secondsFromGMT: 0) ?? .current).year().month()
        )
        let status: String?
        switch metadata?.status {
        case "Continuing": status = String(localized: "连载中")
        case "Ended": status = String(localized: "已完结")
        case "Upcoming": status = String(localized: "即将播出")
        default: status = metadata?.status
        }
        return [month, status, metadata?.rating].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " · ")
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
    var carouselArtwork: EmbyFeaturedArtwork? = nil
    var opensFavorites: Bool { item == nil && origin == .favorites }
    var opensLibrary: Bool { item == nil && !opensFavorites }

    static func favorites(_ source: MediaSource) -> Self {
        Self(source: source, title: String(localized: "收藏媒体"), itemID: "", item: nil, origin: .favorites)
    }

    static func library(_ source: MediaSource, id: String, title: String) -> Self {
        Self(source: source, title: title, itemID: id, item: nil)
    }

    static func detail(_ source: MediaSource, _ item: MediaItem, origin: Origin, carouselArtwork: EmbyFeaturedArtwork? = nil) -> Self {
        Self(source: source, title: item.title, itemID: item.id.localID, item: item, origin: origin,
             carouselArtwork: carouselArtwork)
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
                EmbySeriesDetailView(source: source, series: item)
                    .navigationTransition(.zoom(sourceID: route, in: artworkZoom))
            )
        }
        return AnyView(EmbyItemDetailView(source: source, item: item))
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

    private let pageSize = 21
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let route = EmbyMediaRoute.detail(source, item, origin: detailOrigin)
                    Button { openDetail(route) } label: {
                        MediaThumbnail(source: source, item: item, fixedHeight: layout.thumbnailHeight)
                            .mediaArtworkBorder()
                            .matchedTransitionSource(id: route, in: artworkZoom)
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
            .padding(12)
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
        .background(VesperTheme.background.ignoresSafeArea())
        .overlay {
            if items.isEmpty && !didLoadFirstPage && errorMessage == nil { VesperPageLoadingOverlay() }
        }
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
    private var cacheKey: String { "browser:\(scope.cacheKey):\(parentID ?? "")" }

    private func loadPage() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let generation = await AppCacheStore.shared.libraryGeneration
            let page = try await EmbyRepository.shared.items(for: source, parentID: parentID,
                                                             startIndex: nextOffset, limit: pageSize,
                                                             sortBy: "DateCreated", sortOrder: "Descending",
                                                             scope: scope)
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
