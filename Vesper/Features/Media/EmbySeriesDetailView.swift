import SwiftUI
import UIKit

struct EmbyPreviewFacts: View {
    let item: MediaItem

    var body: some View {
        let metadata = item.embyPresentation
        let date = metadata?.premiereDate?.formatted(
            Date.FormatStyle(timeZone: TimeZone(secondsFromGMT: 0) ?? .current).year().month().day()
        )
        let kind: String? = switch item.embyItemType {
        case "Series": String(localized: "剧集")
        case "Movie": String(localized: "电影")
        default: nil
        }
        let details = ([date, kind].compactMap { $0 } + (metadata?.genres ?? []).prefix(3))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !details.isEmpty {
            Text(verbatim: details.joined(separator: " · "))
                .font(.caption)
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

    var body: some View {
        VStack(spacing: 8) {
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
                .font(.caption)
                .lineLimit(1)
            }
        }
    }

    private var facts: [String] {
        var facts = [series.subtitle].compactMap { $0 }
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

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var playback: PlaybackSession
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @State private var metadata: EmbySeriesMetadata?
    @State private var episodes: [EmbyEpisode] = []
    @State private var seasonNumbers: [Int] = []
    @State private var similar: [MediaItem] = []
    @State private var leadingEpisode: MediaID?
    @State private var selectedSeason: Int?
    @State private var busy: Set<MediaID> = []
    @State private var presentedItem: MediaItem?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var isLoading = true

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero(width: width)
                    episodeSection(width: width)
                    similarSection
                    creditsSection
                    linksSection
                }
                .padding(.bottom, 20)
            }
        }
        .background(VesperTheme.background.ignoresSafeArea())
        .navigationTitle(series.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .sheet(item: $presentedItem) { item in
            NavigationStack { embySheetDetails(source: source, item: item) }
        }
        .alert("无法更新观看记录", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button("好", role: .cancel) { actionError = nil }
        } message: { Text(verbatim: actionError ?? "") }
        .task(id: series.id) { await load() }
    }

    private func hero(width: CGFloat) -> some View {
        let item = metadata?.item ?? series
        return EmbyFeaturedPage(source: source, item: item, size: CGSize(width: width, height: width * 5 / 3),
                                artwork: nil, artworkIsPrepared: false, featuredArtwork: nil,
                                featuredArtworkIsPrepared: false, showsPageControl: false, showsInformation: true,
                                seriesFooter: EmbySeriesHeroFooter(series: item, season: selectedSeason,
                                                                  seasonCount: seasonNumbers.count,
                                                                  episodes: episodes.filter { $0.season == selectedSeason }))
    }

    @ViewBuilder
    private func episodeSection(width: CGFloat) -> some View {
        if !episodes.isEmpty {
            seasonMenu
                .padding(.horizontal, 20)
            let margin = CGFloat(layout[.endPadding])
            let cardWidth = min(745, max(1, width - 2 * margin))
            episodeShelf(cardWidth: cardWidth)
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity).padding()
        } else if let loadError {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: loadError).font(.footnote).foregroundStyle(.secondary)
                Button("重试") { Task { await load() } }
            }
            .padding(.horizontal, 20)
        } else {
            Text("暂无分集").foregroundStyle(.secondary).padding(.horizontal, 20)
        }
    }

    private var seasonMenu: some View {
        Menu {
            ForEach(seasonNumbers, id: \.self) { season in
                Button {
                    guard let first = episodes.first(where: { $0.season == season }) else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
                        selectedSeason = season
                        leadingEpisode = first.id
                    }
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
                Text(verbatim: embySeasonName(selectedSeason ?? seasonNumbers.first ?? 1))
                    .contentTransition(.numericText(value: Double(selectedSeason ?? 0)))
                    .clipped()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemGray2))
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
        }
    }

    private func episodeShelf(cardWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 13) {
                ForEach(episodes) { episode in
                    EmbyEpisodeCard(source: source, episode: episode, width: cardWidth,
                                    position: resumePosition(episode), isBusy: busy.contains(episode.id),
                                    open: { presentedItem = episode.item },
                                    clear: { update(episode, markPlayed: false) },
                                    mark: { update(episode, markPlayed: true) })
                        .id(episode.id)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, CGFloat(layout[.endPadding]), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(anchor: .leading))
        .scrollPosition(id: $leadingEpisode, anchor: .leading)
        .scrollIndicators(.hidden)
        .onChange(of: leadingEpisode) { _, id in
            guard let season = episodes.first(where: { $0.id == id })?.season, season != selectedSeason else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) { selectedSeason = season }
        }
    }

    @ViewBuilder
    private var similarSection: some View {
        if !similar.isEmpty {
            Text("类似作品").font(.system(size: 16, weight: .semibold)).padding(.horizontal, 20)
            shelf {
                ForEach(similar) { item in
                    Button { presentedItem = item } label: {
                        MediaThumbnail(source: source, item: item)
                            .frame(width: CGFloat(layout[.itemWidth]), height: CGFloat(layout[.itemHeight]))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.gray.opacity(0.55), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: item.title))
                    .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback,
                                                 showsEmbyFacts: true) { EmptyView() })
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
                    VStack(spacing: 6) {
                        Group {
                            if let image = credit.image {
                                MediaThumbnail(source: source, item: image, aspectRatio: 1)
                            } else {
                                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 78, height: 78)
                        .clipShape(Circle())
                        Text(verbatim: credit.name).font(.subheadline).lineLimit(1)
                        Text(verbatim: credit.role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: 104)
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
                            .background(.thinMaterial, in: Capsule())
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
        .scrollTargetBehavior(.viewAligned(anchor: .leading))
        .scrollIndicators(.hidden)
    }

    private func resumePosition(_ episode: EmbyEpisode) -> Double {
        max(episode.item.resumePosition ?? 0, playback.savedProgress(for: episode.item))
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        let repository = EmbyRepository.shared
        async let info = try? repository.seriesMetadata(for: series, source: source)
        async let recommendations = try? repository.similarTitles(for: series, source: source)
        async let episodeRequest = repository.seriesEpisodes(for: series, source: source)
        if let details = await info, !Task.isCancelled { metadata = details }
        do {
            let fetched = try await episodeRequest
            try Task.checkCancellation()
            episodes = fetched
            seasonNumbers = Array(Set(fetched.map(\.season))).sorted()
            selectedSeason = seasonNumbers.first
            leadingEpisode = fetched.first?.id
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
        let fetchedSimilar = await recommendations
        guard !Task.isCancelled else { return }
        similar = fetchedSimilar ?? []
    }

    private func update(_ episode: EmbyEpisode, markPlayed: Bool) {
        guard busy.insert(episode.id).inserted else { return }
        Task {
            defer { busy.remove(episode.id) }
            do {
                if markPlayed || (episode.item.resumePosition ?? 0) > 0 {
                    try await EmbyRepository.shared.updateEpisode(episode, source: source, markPlayed: markPlayed)
                }
                if let index = episodes.firstIndex(where: { $0.id == episode.id }) {
                    episodes[index].item.resumePosition = 0
                    if markPlayed { episodes[index].played = true }
                }
                playback.clearSavedProgress(for: episode.item)
            } catch { actionError = error.localizedDescription }
        }
    }
}

// Recommendations can lead to another series, so keep recursive sheet content erased.
@MainActor
func embySheetDetails(source: MediaSource, item: MediaItem) -> AnyView {
    if item.isEmbySeries {
        return AnyView(EmbySeriesDetailView(source: source, series: item, showsCloseButton: true))
    }
    return AnyView(EmbyItemDetailView(source: source, item: item, showsCloseButton: true))
}

private struct EmbyEpisodeCard: View {
    let source: MediaSource
    let episode: EmbyEpisode
    let width: CGFloat
    let position: Double
    let isBusy: Bool
    let open: () -> Void
    let clear: () -> Void
    let mark: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?
    @State private var bottomStrip: UIImage?

    private var height: CGFloat { width * 690 / 745 }
    private var title: String { episode.number.map { String(localized: "第\($0)集") } ?? String(localized: "单集") }

    var body: some View {
        ZStack(alignment: .top) {
            VesperTheme.background
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: width, height: height * 0.61, alignment: .top)
            }
            VStack {
                Spacer(minLength: 0)
                details
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.gray.opacity(0.4), lineWidth: 1) }
        .contentShape(Rectangle())
        .contextMenu { actions } preview: {
            VStack(alignment: .leading, spacing: 8) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: episode.item.title).font(.headline).lineLimit(2)
            }
            .frame(width: 280)
            .padding(12)
        }
        .task(id: AppCacheStore.embyArtworkKey(for: episode.item, source: source)) {
            guard let data = await MediaThumbnailLoader.shared.load(episode.item, source: source),
                  !Task.isCancelled, let decoded = UIImage(data: data) else { return }
            image = decoded
            if let cgImage = decoded.cgImage {
                let depth = max(1, cgImage.height / 6)
                bottomStrip = cgImage.cropping(to: CGRect(x: 0, y: cgImage.height - depth,
                                                        width: cgImage.width, height: depth)).map { UIImage(cgImage: $0) }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: episode.item.title).font(.headline).lineLimit(1)
            Text(verbatim: episode.item.embyPresentation?.overview ?? "")
                .font(.subheadline)
                .lineLimit(3, reservesSpace: true)
            playbackRow
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: height * 0.5, alignment: .bottomLeading)
        .background {
            GeometryReader { geometry in
                ZStack {
                    if let bottomStrip {
                        Image(uiImage: bottomStrip).resizable()
                            .frame(width: geometry.size.width, height: geometry.size.height + 42)
                            .blur(radius: 22)
                    }
                    (colorScheme == .dark ? Color.black : Color.white).opacity(0.66)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .mask {
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                           .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                }
            }
        }
    }

    private var playbackRow: some View {
        HStack(spacing: 7) {
            if episode.played {
                Image(systemName: "arrow.clockwise").accessibilityLabel("已观看")
            } else if position > 0 {
                Image(systemName: "play.fill").accessibilityLabel("有播放进度")
                if let duration = episode.item.duration, duration > 0 {
                    ProgressView(value: min(position / duration, 1)).frame(width: 38)
                }
            }
            if let duration = episode.item.duration, duration > 0 {
                Text(verbatim: mediaTimeLabel(duration)).monospacedDigit()
            }
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
                .disabled(isBusy)
        }
        if !episode.played {
            Button("标记为已观看", systemImage: "checkmark.circle", action: mark)
                .disabled(isBusy || source.emby?.userID == nil)
        }
    }
}
