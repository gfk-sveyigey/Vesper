import SwiftUI
import UIKit

@MainActor
final class MediaLayoutSettings: ObservableObject {
    static let shared = MediaLayoutSettings()

    enum Metric: String, CaseIterable {
        case thumbnailHeight, groupSpacing, titlePadding, scrollPadding
        case itemWidth, itemHeight, itemVerticalPadding, itemSpacing, endPadding, episodeCardWidth, episodeCardHeight

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
            }
        }

        var range: ClosedRange<Int> {
            switch self {
            case .thumbnailHeight: 0...600
            case .itemWidth, .itemHeight: 24...480
            case .episodeCardWidth, .episodeCardHeight: 120...1200
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
    @Namespace private var artworkZoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsEmbyShortcuts = false

    var body: some View {
        Group {
            if let source = library.selectedSource, source.kind == .local {
                LocalFilesView(source: source) { mediaSourceMenu }
                    .id(source.id)
            } else {
                mediaContent
            }
        }
        .onChange(of: library.selectedID) { _, _ in showsEmbyShortcuts = false }
        .navigationDestination(for: EmbyMediaRoute.self) { route in
            if route.opensLibrary || route.opensFavorites {
                EmbySeriesBrowserView(source: route.source, groupTitle: route.title,
                                      parentID: route.opensFavorites ? nil : route.itemID,
                                      scope: route.opensFavorites ? .favorites : .titles,
                                      artworkZoom: artworkZoom, openDetail: { path.append($0) })
            } else if let item = route.item {
                if item.isEmbySeries {
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
        return VesperRootScrollView(title: "媒体", extendsContentUnderHeader: !featured.isEmpty,
                                   showsLoading: isLoadingMedia, usesMediaScrollEdges: true,
                                   onVerticalOffsetChange: updateEmbyShortcuts) {
            VStack(alignment: .leading, spacing: 20) {
                if let source = library.selectedSource, !featured.isEmpty {
                    EmbyFeaturedCarousel(source: source, items: featured, artwork: library.embyHome?.artwork,
                                         featuredArtwork: library.embyHome?.featuredArtwork, artworkZoom: artworkZoom,
                                         isMediaRoot: path.isEmpty)
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
                Button { library.navigateEmbyBack() } label: { Image(systemName: "chevron.left") }
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
            if home.groups.isEmpty {
                VesperCenteredEmptyContent(message: "来源中暂无媒体", symbol: AppSection.media.symbol)
            } else {
                VStack(alignment: .leading, spacing: CGFloat(layout[.groupSpacing])) {
                    ForEach(home.groups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            groupTitle(group, source: source)
                            if !group.isLoading && group.items.isEmpty {
                                Group {
                                    if let errorMessage = group.errorMessage {
                                        Text(verbatim: errorMessage)
                                    } else {
                                        Text("暂无媒体")
                                    }
                                }
                                .font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20).padding(.vertical, 16)
                            } else {
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
                                .scrollTargetBehavior(.viewAligned(anchor: .leading))
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

    private func updateEmbyShortcuts(offset: CGFloat) {
        guard embyHomeSource != nil else { return }
        let expanded = offset <= -18 || (showsEmbyShortcuts && offset <= 1)
        guard expanded != showsEmbyShortcuts else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            showsEmbyShortcuts = expanded
        }
    }

    @ViewBuilder
    private var mediaSourceMenu: some View {
        if let source = embyHomeSource, showsEmbyShortcuts {
            HStack(spacing: 0) {
                refreshButton
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                favoritesButton(source)
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                sourceMenuButton
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            sourceMenuButton.glassEffect(.regular.interactive(), in: .circle)
        }
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
        let image = source.emby?.iconData.flatMap { UIImage(data: $0) } ?? UIImage(named: "EmbyLogo")
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return Image(systemName: sourceSymbol(source))
        }
        let format = UIGraphicsImageRendererFormat()
        let canvas = CGSize(width: size, height: size)
        let icon = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: canvas)
            UIBezierPath(roundedRect: bounds, cornerRadius: size * 0.23).addClip()
            if source.emby?.iconData == nil {
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fill(bounds)
            }
            let inset = source.emby?.iconData == nil ? size * 0.09 : 0
            let available = size - 2 * inset
            let scale = inset > 0
                ? min(available / image.size.width, available / image.size.height)
                : max(available / image.size.width, available / image.size.height)
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
    let artworkZoom: Namespace.ID
    let isMediaRoot: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: MediaID?
    @State private var incoming: MediaID?
    @State private var direction = 1
    @State private var progress = 0.0
    @State private var isDragging = false
    @State private var transitionID: UUID?

    private let mirrorFraction: CGFloat = 0.18
    private let travelFraction: CGFloat = 0.12

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let page = currentIndex
            let isTransitioning = isDragging || transitionID != nil
            ZStack {
                // Keep adjacent artwork mounted so a pan can reveal it immediately.
                ForEach(visiblePages(around: page)) { item in
                    let isCurrent = item.id == items[page].id
                    let isIncoming = item.id == incoming
                    let shift = reduceMotion ? 0 : CGFloat(direction) * width * travelFraction
                    let route = EmbyMediaRoute.detail(source, item, origin: .carousel)
                    NavigationLink(value: route) {
                        EmbyFeaturedPage(source: source, item: item, size: geometry.size,
                                         artwork: artwork?[item.id.localID], artworkIsPrepared: artwork != nil,
                                         featuredArtwork: featuredArtwork?[item.id],
                                         featuredArtworkIsPrepared: featuredArtwork != nil,
                                         showsPageControl: items.count > 1,
                                         showsInformation: isCurrent && !isTransitioning,
                                         mirroredEdgeFraction: (isCurrent || isIncoming) && isTransitioning && !reduceMotion ? mirrorFraction : 0)
                            .matchedTransitionSource(id: route, in: artworkZoom)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: item.title))
                    .opacity(isCurrent || isIncoming ? 1 : 0)
                    .frame(width: width)
                    .offset(x: isCurrent ? -shift * progress : shift * (1 - progress))
                    .padding(.horizontal, width * mirrorFraction)
                    .mask {
                        if isIncoming { transitionMask(width: width) }
                        else { Rectangle() }
                    }
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
                    .fixedSize()
                    .padding(.bottom, 12)
                    .allowsHitTesting(!isTransitioning)
                }
            }
            .modifier(EmbyPosterStretch(geometry: geometry))
        }
        .aspectRatio(3.0 / 5.0, contentMode: .fit)
        .onChange(of: items.map(\.id), initial: true) { _, ids in
            resetTransition()
            if selection.map(ids.contains) != true { selection = ids.first }
        }
        .onDisappear { resetTransition() }
        .task(id: RotationState(items: items.map(\.id), selection: selection, enabled: canRotate)) {
            guard canRotate else { return }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard !Task.isCancelled, canRotate else { return }
            startTransition(to: wrappedIndex(currentIndex + 1), direction: 1)
        }
    }

    @ViewBuilder
    private func transitionMask(width: CGFloat) -> some View {
        if reduceMotion {
            Rectangle().opacity(progress)
        } else {
            let blendWidth = width * 0.4
            let maskWidth = width + blendWidth
            // The leading edge of the reveal travels across the entire viewport.
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: 2.0 / 7.0),
                                   .init(color: .black, location: 1)],
                           startPoint: UnitPoint(x: 0, y: 0.5), endPoint: UnitPoint(x: 1, y: 0.5))
                .frame(width: maskWidth)
                .offset(x: width + blendWidth / 2 - maskWidth * progress)
                .frame(width: width)
                .scaleEffect(x: CGFloat(direction), y: 1)
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
        let items: [MediaID]
        let selection: MediaID?
        let enabled: Bool
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
    }
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

struct EmbyFeaturedPage: View {
    let source: MediaSource
    let item: MediaItem
    let size: CGSize
    let artwork: Data?
    let artworkIsPrepared: Bool
    let featuredArtwork: EmbyFeaturedArtwork?
    let featuredArtworkIsPrepared: Bool
    let showsPageControl: Bool
    let showsInformation: Bool
    var seriesFooter: EmbySeriesHeroFooter? = nil
    var mirroredEdgeFraction: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedArtwork: EmbyFeaturedArtwork?

    var body: some View {
        let images = featuredArtworkIsPrepared ? featuredArtwork : loadedArtwork
        MediaThumbnail(source: source, item: item, cornerRadius: 0, fixedHeight: size.height,
                       preloadedData: images?.poster ?? artwork,
                       artworkIsPrepared: images?.poster != nil || artworkIsPrepared,
                       mirroredEdgeFraction: mirroredEdgeFraction,
                       showsMissingArtwork: featuredArtworkIsPrepared || loadedArtwork != nil)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if let logo = images?.logo, let image = UIImage(data: logo) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: size.width * 0.68, maxHeight: size.height * 0.15)
                    } else {
                        Text(verbatim: item.title)
                            .font(.largeTitle.weight(.semibold))
                            .lineLimit(2)
                    }
                    VStack(spacing: 4) {
                        Text(verbatim: firstLine)
                        if !secondLine.isEmpty { Text(verbatim: secondLine) }
                    }
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    if let seriesFooter {
                        seriesFooter.padding(.top, 10)
                    }
                }
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                .shadow(color: (colorScheme == .dark ? Color.black : Color.white).opacity(0.65), radius: 3, y: 1)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.bottom, showsPageControl ? 60 : 18)
                .frame(maxWidth: .infinity)
                .frame(minHeight: size.height * 0.4, alignment: .bottom)
                .background {
                    Rectangle()
                        .fill(.regularMaterial)
                        .opacity(0.55)
                        .overlay(colorScheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.14))
                        .mask {
                            LinearGradient(stops: [.init(color: .clear, location: 0),
                                                   .init(color: .black, location: 0.5),
                                                   .init(color: .black, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                }
                .opacity(showsInformation ? 1 : 0)
                .animation(.easeInOut(duration: 0.16), value: showsInformation)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .task(id: item) {
                guard !featuredArtworkIsPrepared else { return }
                loadedArtwork = nil
                let images = await MediaThumbnailLoader.shared.featuredArtwork(for: item, source: source)
                if !Task.isCancelled { loadedArtwork = images }
            }
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
        uiView.size(forNumberOfPages: count)
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
    }

    let source: MediaSource
    let title: String
    let itemID: String
    let item: MediaItem?
    var origin: Origin? = nil
    var opensFavorites: Bool { item == nil && origin == .favorites }
    var opensLibrary: Bool { item == nil && !opensFavorites }

    static func favorites(_ source: MediaSource) -> Self {
        Self(source: source, title: String(localized: "收藏媒体"), itemID: "", item: nil, origin: .favorites)
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
                    let route = EmbyMediaRoute.detail(source, item, origin: parentID.map { .library($0) } ?? .favorites)
                    NavigationLink(value: route) {
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
                Text(scope == .favorites ? "暂无收藏媒体" : "暂无媒体").foregroundStyle(.secondary).padding()
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

    private var cacheScope: String { AppCacheStore.scope(for: source) }
    private var cacheKey: String { "browser:\(scope.rawValue):\(parentID ?? "")" }

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
