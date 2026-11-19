import SwiftUI
import UIKit

struct EmbyPreviewFacts: View {
    let item: MediaItem

    var body: some View {
        let metadata = item.embyPresentation
        let date = metadata?.premiereDate.flatMap { date -> String? in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { return nil }
            return String(format: "%04d.%02d", year, month)
        }
        let kind: String? = switch item.embyItemType {
        case "Series": String(localized: "剧集")
        case "Movie": String(localized: "电影")
        default: nil
        }
        let tags = ([kind].compactMap { $0 } + (metadata?.genres ?? []).prefix(3))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " · ")
        let details = [date, tags.isEmpty ? nil : tags].compactMap { $0 }.joined(separator: "  ")
        if !details.isEmpty {
            Text(verbatim: details)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

struct EmbySeriesHeroFooter: View {
    let series: MediaItem
    let season: Int?
    let seasonCount: Int
    let episodes: [EmbyEpisode]
    var runtime: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: series.embyPresentation?.overview ?? "")
                .font(.subheadline)
                .lineLimit(2, reservesSpace: true)
            if !facts.isEmpty || !episodes.isEmpty {
                HStack(spacing: 7) {
                    Text(verbatim: facts.joined(separator: " · "))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if episodes.contains(where: \.is4K) {
                        Image(systemName: "4k.tv")
                            .accessibilityLabel("4K")
                    }
                    if episodes.contains(where: \.dolbyVision) {
                        Text("Dolby Vision").fontWeight(.semibold)
                    }
                    if episodes.contains(where: \.dolbyAtmos) {
                        Text("Dolby Atmos").fontWeight(.semibold)
                    }
                }
                .font(.subheadline)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    private var facts: [String] {
        var facts = [series.subtitle].compactMap { $0 }
        if let runtime { facts.append(runtime) }
        if let season {
            if seasonCount > 1 {
                facts.append(String(localized: "\(embySeasonName(season))/共\(seasonCount)季"))
            }
            facts.append(String(localized: "\(episodes.count)集"))
        }
        return facts
    }
}

private func embySeasonName(_ number: Int) -> String {
    number == 0 ? String(localized: "特别篇") : String(localized: "第\(number)季")
}

struct EmbySeriesDetailView: View {
    let source: MediaSource
    let series: MediaItem
    var showsCloseButton = false
    var carouselArtwork: EmbyFeaturedArtwork? = nil
    var episode: EmbyEpisode? = nil
    var parentSeries: MediaItem? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var playback: PlaybackSession
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @State private var metadata: EmbyDetailMetadata?
    @State private var episodes: [EmbyEpisode] = []
    @State private var seasonNumbers: [Int] = []
    @State private var similar: [MediaItem] = []
    @State private var leadingEpisode: MediaID?
    @State private var selectedSeason: Int?
    @State private var seasonMovesForward = true
    @State private var openedEpisodeID: MediaID?
    @State private var hasScrolled = false
    @Namespace private var recommendationZoom
    @State private var busy: Set<MediaID> = []
    @State private var openedRecommendation: MediaItem?
    @State private var openedPerson: EmbyPerson?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var isLoading = true
    @State private var loadedSeriesID: MediaID?
    @State private var reloadID = 0
    @State private var clearedServerProgress = false

    private var item: MediaItem { metadata?.item ?? series }
    private var isEpisode: Bool { episode != nil || item.embyItemType == "Episode" }

    private var runtime: String? {
        guard let duration = item.duration, duration.isFinite, duration > 0 else { return nil }
        return Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private var episodeTitle: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? episodeNumberLabel ?? String(localized: "单集") : title
    }

    private var episodeNumberLabel: String? {
        (metadata?.episodeNumber ?? episode?.number).map { String(localized: "第\($0)集") }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if isEpisode { episodeHero } else { hero }
                    if series.isEmbySeries {
                        episodeSection(viewportWidth: width)
                    } else {
                        playbackSection
                        if isEpisode { parentSeriesSection }
                        technicalSection
                        if let loadError {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: loadError).font(.footnote).foregroundStyle(.secondary)
                                Button("重试") { reloadID += 1 }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    similarSection
                    creditsSection
                    linksSection
                }
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollEdgeEffectHidden(true, for: .top)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 0.5
            } action: { _, hasScrolled in
                self.hasScrolled = hasScrolled
            }
        }
        .overlay(alignment: .top) {
            VesperMediaStatusBarBlur(isVisible: hasScrolled)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(VesperTheme.background.ignoresSafeArea())
        .navigationTitle(isEpisode ? episodeTitle : item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
            if showsCloseButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .navigationDestination(item: $openedEpisodeID) { id in
            if let episode = episodes.first(where: { $0.id == id }) {
                EmbyItemDetailView(source: source, item: episode.item, episode: episode, parentSeries: item)
            }
        }
        .navigationDestination(item: $openedRecommendation) { item in
            recommendationDestination(for: item)
        }
        .navigationDestination(item: $openedPerson) { person in
            EmbyPersonWorksView(source: source, person: person)
        }
        .alert("无法更新观看记录", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button("好", role: .cancel) { actionError = nil }
        } message: { Text(verbatim: actionError ?? "") }
        .task(id: "\(series.id.sourceID):\(series.id.localID):\(reloadID)") {
            guard loadedSeriesID != series.id else { return }
            await loadDetail()
        }
    }

    // A recommendation can open another instance of this view.
    private func recommendationDestination(for item: MediaItem) -> AnyView {
        if item.isEmbySeries {
            if isEpisode { return AnyView(EmbySeriesDetailView(source: source, series: item)) }
            return AnyView(
                EmbySeriesDetailView(source: source, series: item)
                    .navigationTransition(.zoom(sourceID: item.id, in: recommendationZoom))
            )
        }
        return AnyView(EmbyItemDetailView(source: source, item: item))
    }

    private var hero: some View {
        GeometryReader { geometry in
            EmbyFeaturedPage(source: source, item: item, size: geometry.size,
                             artwork: nil, artworkIsPrepared: false, featuredArtwork: carouselArtwork,
                             featuredArtworkIsPrepared: carouselArtwork?.poster != nil, showsInformation: true,
                             seriesFooter: EmbySeriesHeroFooter(series: item, season: selectedSeason,
                                                               seasonCount: seasonNumbers.count,
                                                               episodes: episodes.filter { $0.season == selectedSeason },
                                                               runtime: series.isEmbySeries ? nil : runtime),
                             seriesFooterOpacity: !series.isEmbySeries || loadedSeriesID == series.id ? 1 : 0)
                .modifier(EmbyPosterStretch(geometry: geometry))
        }
        .aspectRatio(EmbyPosterLayout.aspectRatio, contentMode: .fit)
    }

    private var episodeHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaThumbnail(source: source, item: item, aspectRatio: 16.0 / 9.0, cornerRadius: 0)
            VStack(alignment: .leading, spacing: 8) {
                let number = episodeNumberLabel == episodeTitle ? nil : episodeNumberLabel
                let season = (metadata?.seasonNumber ?? episode?.season).map(embySeasonName)
                let context = [(parentSeries ?? metadata?.series)?.title, season, number]
                    .compactMap { $0 }.joined(separator: " · ")
                if !context.isEmpty {
                    Text(verbatim: context).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(verbatim: episodeTitle).font(.title.bold()).accessibilityAddTraits(.isHeader)
                if let overview = item.embyPresentation?.overview, !overview.isEmpty {
                    Text(verbatim: overview).font(.subheadline)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var playbackSection: some View {
        let played = playback.effectivePlayed(for: item)
        let serverPosition = clearedServerProgress ? nil : item.resumePosition
        let position = serverPosition ?? playback.savedProgress(for: item)
        let progressDuration = item.duration.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        return VStack(alignment: .leading, spacing: 8) {
            if isEpisode || played || (position > 0 && progressDuration != nil) {
                HStack(spacing: 10) {
                    if played {
                        Label("已观看", systemImage: "checkmark.circle")
                    }
                    if position > 0, let progressDuration {
                        ProgressView(value: min(position, progressDuration), total: progressDuration)
                            .accessibilityLabel("播放进度")
                    }
                    if isEpisode {
                        Text(verbatim: runtime ?? String(localized: "未知时长"))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    var playable = item
                    if clearedServerProgress { playable.resumePosition = 0 }
                    playback.play(playable, in: source, queue: [playable])
                } label: {
                    Label(position > 0 && !played ? "继续播放" : "播放", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if source.emby?.userID != nil {
                    Menu {
                        Button(played ? "标记为未观看" : "标记为已观看",
                               systemImage: played ? "circle" : "checkmark.circle") {
                            playback.setPlayed(!played, for: item, source: source) { actionError = $0 }
                        }
                        if position > 0 {
                            Button("清除播放进度", systemImage: "clock.arrow.circlepath") {
                                clearItemProgress()
                            }
                            .disabled(busy.contains(item.id))
                        }
                    } label: {
                        Label("观看记录", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var parentSeriesSection: some View {
        if let parent = parentSeries ?? metadata?.series {
            Button {
                openedRecommendation = parent
            } label: {
                HStack(spacing: 12) {
                    MediaThumbnail(source: source, item: parent)
                        .frame(width: 44)
                        .mediaArtworkBorder()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("所属剧集").font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: parent.title).font(.headline)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private var technicalSection: some View {
        if let video = metadata?.video, video.dimensions != nil || !video.technical.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("媒体信息").font(.headline).accessibilityAddTraits(.isHeader)
                if let dimensions = video.dimensions {
                    LabeledContent("分辨率", value: dimensions)
                }
                ForEach(Array(video.technical.enumerated()), id: \.offset) { _, field in
                    LabeledContent(field.label, value: field.value)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private func episodeSection(viewportWidth: CGFloat) -> some View {
        if !episodes.isEmpty {
            seasonMenu
                .padding(.horizontal, 20)
            let margin = CGFloat(layout[.endPadding])
            let cardWidth = min(layout.episodeCardWidth, max(1, viewportWidth - margin * 2))
            episodeShelf(cardWidth: cardWidth)
        } else if isLoading {
            Text("")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .padding(.horizontal, 20)
            episodeLoadingPlaceholders(viewportWidth: viewportWidth)
        } else if let loadError {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: loadError).font(.footnote).foregroundStyle(.secondary)
                Button("重试") { Task { await loadEpisodes() } }
            }
            .padding(.horizontal, 20)
        } else if !isLoading {
            Text("暂无分集").foregroundStyle(.secondary).padding(.horizontal, 20)
        }
    }

    private func episodeLoadingPlaceholders(viewportWidth: CGFloat) -> some View {
        let margin = CGFloat(layout[.endPadding])
        let cardWidth = min(layout.episodeCardWidth, max(1, viewportWidth - margin * 2))
        return ScrollView(.horizontal) {
            LazyHStack(spacing: 13) {
                ForEach(0..<2, id: \.self) { _ in
                    MediaCardBackdrop()
                        .frame(width: cardWidth, height: layout.episodeCardHeight)
                        .mediaArtworkBorder()
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never, anchor: .leading))
        .scrollIndicators(.hidden)
        .accessibilityLabel("正在加载分集")
    }

    @ViewBuilder
    private var seasonMenu: some View {
        if seasonNumbers.count > 1 {
            Menu {
                ForEach(seasonNumbers, id: \.self) { season in
                    Button {
                        guard let first = episodes.first(where: { $0.season == season }) else { return }
                        selectSeason(season, firstEpisode: first.id)
                    } label: {
                        if selectedSeason == season {
                            Label(embySeasonName(season), systemImage: "checkmark")
                        } else {
                            Text(verbatim: embySeasonName(season))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    seasonTitle
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            seasonTitle
        }
    }

    private var seasonTitle: some View {
        let season = selectedSeason ?? seasonNumbers.first ?? 1
        let entry: Edge = seasonMovesForward ? .bottom : .top
        let exit: Edge = seasonMovesForward ? .top : .bottom
        return ZStack(alignment: .leading) {
            Text(verbatim: embySeasonName(season))
                .id(season)
                .transition(reduceMotion ? .identity : .asymmetric(insertion: .move(edge: entry), removal: .move(edge: exit)))
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.primary)
        .clipped()
    }

    private func selectSeason(_ season: Int, firstEpisode: MediaID? = nil) {
        if let selectedSeason, selectedSeason != season {
            seasonMovesForward = season > selectedSeason
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
            selectedSeason = season
            if let firstEpisode { leadingEpisode = firstEpisode }
        }
    }

    private func episodeShelf(cardWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 13) {
                ForEach(episodes) { episode in
                    EmbyEpisodeCard(source: source, episode: episode, width: cardWidth,
                                    height: layout.episodeCardHeight, position: resumePosition(episode), isBusy: busy.contains(episode.id),
                                    open: { openedEpisodeID = episode.id },
                                    clear: { clearProgress(for: episode) },
                                    setPlayed: { played in
                                        playback.setPlayed(played, for: episode.item, source: source) { actionError = $0 }
                                    })
                        .id(episode.id)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, CGFloat(layout[.endPadding]), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never, anchor: .leading))
        .scrollPosition(id: $leadingEpisode, anchor: .leading)
        .scrollIndicators(.hidden)
        .onChange(of: leadingEpisode) { _, id in
            guard let season = episodes.first(where: { $0.id == id })?.season, season != selectedSeason else { return }
            selectSeason(season)
        }
    }

    @ViewBuilder
    private var similarSection: some View {
        if !similar.isEmpty {
            Text("类似作品").font(.system(size: 16, weight: .semibold)).padding(.horizontal, 20)
            shelf {
                ForEach(similar) { item in
                    Button { openedRecommendation = item } label: {
                        MediaThumbnail(source: source, item: item)
                            .frame(width: CGFloat(layout[.itemWidth]), height: CGFloat(layout[.itemHeight]))
                            .mediaArtworkBorder()
                            .matchedTransitionSource(id: item.id, in: recommendationZoom)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: item.title))
                    .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback,
                                                 showsEmbyFacts: true, openEmbyDetails: { openedRecommendation = item }) { EmptyView() })
                }
            }
        }
    }

    @ViewBuilder
    private var creditsSection: some View {
        if let credits = metadata?.credits, !credits.isEmpty {
            Text("演职人员").font(.system(size: 16, weight: .semibold)).padding(.horizontal, 20)
            shelf {
                ForEach(credits) { credit in
                    Button { openedPerson = credit.person } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let image = credit.image {
                                    MediaThumbnail(source: source, item: image, aspectRatio: 1,
                                                   missingArtworkSymbol: "person.crop.circle.fill")
                                } else {
                                    MediaCardBackdrop(showsMissingArtwork: true,
                                                      missingArtworkSymbol: "person.crop.circle.fill")
                                }
                            }
                            .frame(width: 78, height: 78)
                            .clipShape(Circle())
                            Text(verbatim: credit.person.name).font(.subheadline).lineLimit(1)
                            Text(verbatim: credit.role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 104)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var linksSection: some View {
        if let links = metadata?.links, !links.isEmpty {
            Text("链接").font(.system(size: 16, weight: .semibold)).padding(.horizontal, 20)
            shelf {
                ForEach(links) { link in
                    Link(destination: link.url) {
                        Label(link.name, systemImage: "arrow.up.right")
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(VesperTheme.mediaCardBackground, in: Capsule())
                            .overlay {
                                Capsule()
                                    .strokeBorder(.primary.opacity(0.18), lineWidth: 1)
                                    .allowsHitTesting(false)
                            }
                    }
                }
            }
        }
    }

    private func shelf<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 13) { content() }
                .scrollTargetLayout()
        }
        .contentMargins(.horizontal, CGFloat(layout[.endPadding]), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never, anchor: .leading))
        .scrollIndicators(.hidden)
    }

    private func resumePosition(_ episode: EmbyEpisode) -> Double {
        max(episode.item.resumePosition ?? 0, playback.savedProgress(for: episode.item))
    }

    private func loadDetail() async {
        let repository = EmbyRepository.shared
        loadError = nil
        async let info = repository.detailMetadata(for: series, source: source)
        async let recommendations = isEpisode ? nil : try? repository.similarTitles(for: series, source: source)
        if series.isEmbySeries { await loadEpisodes() }
        do {
            let details = try await info
            try Task.checkCancellation()
            metadata = details
            loadedSeriesID = series.id
        } catch {
            if !Task.isCancelled {
                if !series.isEmbySeries { loadError = error.localizedDescription }
                loadedSeriesID = series.isEmbySeries ? series.id : nil
            }
        }
        let relatedTitles = await recommendations
        if !Task.isCancelled { similar = relatedTitles ?? [] }
    }

    private func clearItemProgress() {
        let target = item
        guard busy.insert(target.id).inserted else { return }
        Task {
            defer { busy.remove(target.id) }
            do {
                try await playback.enqueueEmbyRecordWrite(.clearProgress, for: target, source: source).value
                playback.clearSavedProgress(for: target)
                clearedServerProgress = true
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func loadEpisodes() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let fetched = try await EmbyRepository.shared.seriesEpisodes(for: series, source: source)
            try Task.checkCancellation()
            episodes = fetched
            seasonNumbers = Array(Set(fetched.map(\.season))).sorted()
            selectedSeason = seasonNumbers.first
            leadingEpisode = fetched.first?.id
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    private func clearProgress(for episode: EmbyEpisode) {
        guard busy.insert(episode.id).inserted else { return }
        Task {
            defer { busy.remove(episode.id) }
            do {
                if (episode.item.resumePosition ?? 0) > 0 {
                    try await playback.enqueueEmbyRecordWrite(.clearProgress, for: episode.item, source: source).value
                }
                if let index = episodes.firstIndex(where: { $0.id == episode.id }) {
                    episodes[index].item.resumePosition = 0
                }
                playback.clearSavedProgress(for: episode.item)
            } catch { actionError = error.localizedDescription }
        }
    }
}

// Recommendations can show a series recursively, so erase the sheet's view type.
@MainActor
func embyDetailsSheet(source: MediaSource, item: MediaItem, artworkZoom: Namespace.ID) -> AnyView {
    if item.isEmbySeries {
        return AnyView(
            NavigationStack {
                EmbySeriesDetailView(source: source, series: item, showsCloseButton: true)
            }
            .navigationTransition(.zoom(sourceID: item.id, in: artworkZoom))
        )
    }
    return AnyView(
        NavigationStack {
            EmbyItemDetailView(source: source, item: item, showsCloseButton: true)
        }
    )
}

extension EmbyEpisode {
    var numberLabel: String {
        number.map { String(localized: "第\($0)集") } ?? String(localized: "单集")
    }

    var displayTitle: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? numberLabel : title
    }
}

struct EmbyItemDetailView: View {
    let source: MediaSource
    let item: MediaItem
    var showsCloseButton = false
    var carouselArtwork: EmbyFeaturedArtwork? = nil
    var episode: EmbyEpisode? = nil
    var parentSeries: MediaItem? = nil

    var body: some View {
        EmbySeriesDetailView(source: source, series: item, showsCloseButton: showsCloseButton,
                             carouselArtwork: carouselArtwork, episode: episode, parentSeries: parentSeries)
    }
}

private struct EmbyEpisodeCard: View {
    let source: MediaSource
    let episode: EmbyEpisode
    let width: CGFloat
    let height: CGFloat
    let position: Double
    let isBusy: Bool
    let open: () -> Void
    let clear: () -> Void
    let setPlayed: (Bool) -> Void

    @EnvironmentObject private var playback: PlaybackSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedArtwork: EpisodeArtwork?

    private struct EpisodeArtwork {
        let key: String
        let image: UIImage?
        let bottomStrip: UIImage?
    }

    private var artworkKey: String { AppCacheStore.embyArtworkKey(for: episode.item, source: source) }

    private var artwork: EpisodeArtwork? {
        loadedArtwork?.key == artworkKey ? loadedArtwork : nil
    }

    private var title: String { episode.displayTitle }
    private var showsEpisodeNumber: Bool { episode.displayTitle != episode.numberLabel }

    private var artworkHeight: CGFloat {
        guard let image = artwork?.image else { return 0 }
        return width * image.size.height / max(1, image.size.width)
    }

    var body: some View {
        let showsMissingArtwork = artwork != nil && artwork?.image == nil

        MediaCardBackdrop(showsMissingArtwork: showsMissingArtwork, iconCenterY: 1.0 / 3)
        .frame(width: width, height: height)
        .overlay(alignment: .top) {
            if let image = artwork?.image {
                ZStack(alignment: .top) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: width, height: artworkHeight)
                        .frame(width: width, height: height, alignment: .top)
                        .clipped()
                    let blendStart = min(height * 0.38, max(0, artworkHeight - 32))
                    blurredArtwork(height: height - blendStart)
                        .offset(y: blendStart)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) { details }
        .mediaArtworkBorder(cornerRadius: 16)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
        .contextMenu { actions } preview: {
            VStack(alignment: .leading, spacing: 8) {
                MediaCardBackdrop(showsMissingArtwork: showsMissingArtwork)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let image = artwork?.image {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                    }
                    .mediaArtworkBorder()
                if showsEpisodeNumber {
                    Text(verbatim: episode.numberLabel).font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: title).font(.headline).lineLimit(2)
            }
            .frame(width: 280)
            .padding(12)
        }
        .task(id: artworkKey) {
            let key = artworkKey
            let data = await MediaThumbnailLoader.shared.load(episode.item, source: source)
            guard !Task.isCancelled else { return }
            let image = data.flatMap { UIImage(data: $0) }
            let bottomStrip = image.flatMap(\.cgImage).flatMap { cgImage in
                let depth = max(1, cgImage.height / 6)
                return cgImage.cropping(to: CGRect(x: 0, y: cgImage.height - depth,
                                                 width: cgImage.width, height: depth)).map { UIImage(cgImage: $0) }
            }
            loadedArtwork = EpisodeArtwork(key: key, image: image, bottomStrip: bottomStrip)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsEpisodeNumber {
                Text(verbatim: episode.numberLabel).font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: title).font(.headline).lineLimit(1)
            Text(verbatim: episode.item.embyPresentation?.overview ?? "")
                .font(.subheadline)
                .lineLimit(3, reservesSpace: true)
            playbackRow
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: height * 0.5, alignment: .bottomLeading)
    }

    private func blurredArtwork(height: CGFloat) -> some View {
        ZStack {
            if let bottomStrip = artwork?.bottomStrip {
                Image(uiImage: bottomStrip).resizable()
                    .frame(width: width + 44, height: height + 44)
                    .blur(radius: 22)
            }
            (colorScheme == .dark ? Color.black.opacity(0.66) : Color.white.opacity(0.74))
        }
        .frame(width: width, height: height)
        .clipped()
        .mask {
            LinearGradient(colors: [.clear, .black], startPoint: .top,
                           endPoint: UnitPoint(x: 0.5, y: min(1, 45 / max(1, height))))
        }
    }

    private var playbackRow: some View {
        HStack(spacing: 7) {
            MediaPlaybackStatus(position: position, duration: episode.item.duration, played: effectivePlayed)
            Spacer()
            Menu { actions } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更多操作")
        }
        .font(.caption)
    }

    @ViewBuilder
    private var actions: some View {
        Button("前往单集", systemImage: "info.circle", action: open)
        if position > 0 {
            Button("清除播放进度", systemImage: "clock.arrow.circlepath", action: clear)
                .disabled(isBusy || ((episode.item.resumePosition ?? 0) > 0 && source.emby?.userID == nil))
        }
        let played = effectivePlayed
        Button(played ? "标记为未观看" : "标记为已观看",
               systemImage: played ? "circle" : "checkmark.circle") {
            setPlayed(!played)
        }
        .disabled(source.emby?.userID == nil)
    }

    private var effectivePlayed: Bool {
        playback.effectivePlayed(for: episode.item)
    }
}
