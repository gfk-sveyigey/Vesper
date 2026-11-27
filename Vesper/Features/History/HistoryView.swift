import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var library: SourceLibrary
    @EnvironmentObject private var playback: PlaybackSession
    @Binding var path: NavigationPath

    private var groups: [HistorySourceGroup] {
        Dictionary(grouping: playback.history.filter {
            $0.hiddenFromHistory != true && (!library.canUsePrivacyMode || library.isPrivacyModeEnabled || !library.isProtected($0.source))
        }, by: { $0.source.id }).values.map { entries in
            HistorySourceGroup(source: entries[0].source, entries: entries.sorted { $0.watchedAt > $1.watchedAt })
        }.sorted { left, right in
            if left.id == library.selectedID { return true }
            if right.id == library.selectedID { return false }
            return left.entries[0].watchedAt > right.entries[0].watchedAt
        }
    }

    var body: some View {
        let groups = groups
        VesperRootScrollView(title: "记录") {
            if groups.isEmpty {
                VesperCenteredEmptyContent(message: "无记录", symbol: AppSection.history.symbol)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            let source = library.sources.first(where: { $0.id == group.id }) ?? group.source
                            Text(verbatim: source.kind == .local ? VesperLocalization.string("本地视频")
                                 : source.kind == .photos ? VesperLocalization.string("相册视频") : source.name)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 20)

                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 12) {
                                    ForEach(group.entries) { entry in
                                        let source = library.sources.first(where: { $0.id == group.id }) ?? group.source
                                        HistoryMediaCard(source: source, entry: entry, queue: group.entries.map(\.item)) { item in
                                            path.append(HistoryDetailRoute(source: source, item: item))
                                        }
                                    }
                                }
                                .scrollTargetLayout()
                                .padding(.vertical, 12)
                            }
                            .scrollIndicators(.hidden)
                            .contentMargins(.horizontal, 20, for: .scrollContent)
                            .scrollTargetBehavior(.viewAligned(limitBehavior: .never, anchor: .leading))
                        }
                    }
                }
            }
        }
        .onAppear { playback.pruneUnavailableHistory() }
        .navigationDestination(for: HistoryDetailRoute.self) { route in
            MediaDetailView(source: route.source, series: route.item)
        }
    }
}

private struct HistoryDetailRoute: Hashable {
    let source: MediaSource
    let item: MediaItem

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source.id == rhs.source.id && lhs.item == rhs.item
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(source.id)
        hasher.combine(item)
    }
}

private struct HistorySourceGroup: Identifiable {
    let source: MediaSource
    let entries: [PlaybackHistoryEntry]
    var id: UUID { source.id }
}

private struct HistoryArtworkCacheEntry: Codable {
    let item: MediaItem
    let posterItem: MediaItem
    let previewTitle: String?
}

/// Artwork may belong to the parent series; playback and menu actions always target the episode.
private struct HistoryMediaCard: View {
    let source: MediaSource
    let entry: PlaybackHistoryEntry
    let queue: [MediaItem]
    let openDetail: (MediaItem) -> Void
    @EnvironmentObject private var playback: PlaybackSession
    @EnvironmentObject private var library: SourceLibrary
    @State private var resolvedItem: MediaItem?
    @State private var posterItem: MediaItem?
    @State private var previewTitle: String?

    private var item: MediaItem { resolvedItem ?? entry.item }

    var body: some View {
        Button {
            if source.kind == .emby { openDetail(item) }
            else { playback.play(item, in: source, queue: queue) }
        } label: {
            MediaThumbnail(source: source, item: posterItem ?? item, playback: playback, historyEntry: entry,
                           imageOrientation: .portrait,
                           artworkIsPrepared: source.kind == .emby && posterItem == nil,
                           usesMediaCardBackdrop: false)
                .frame(width: 132, height: 198)
                .mediaArtworkBorder()
        }
        .contentShape(Rectangle())
        .clipped()
        .buttonStyle(.plain)
        .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback, historyEntry: entry,
                                     artworkItem: posterItem, previewTitle: previewTitle,
                                     openEmbyDetails: { openDetail(item) }) { EmptyView() })
        .accessibilityLabel(Text(verbatim: previewTitle ?? entry.title))
        .task(id: "\(AppCacheStore.scope(for: source))|\(entry.mediaID.localID)") {
            await loadArtworkIdentity()
        }
    }

    private func loadArtworkIdentity() async {
        guard source.kind == .emby else { return }
        let cacheKey = "history-artwork|\(AppCacheStore.scope(for: source))|\(entry.mediaID.localID)"
        let (cachedData, generation) = await AppCacheStore.shared.imageMetadata(key: cacheKey)
        let cached = cachedData.flatMap { try? JSONDecoder().decode(HistoryArtworkCacheEntry.self, from: $0) }
        if let cached {
            resolvedItem = cached.item
            posterItem = cached.posterItem
            previewTitle = cached.previewTitle
        }

        do {
            let metadata = try await library.seriesCatalog.detailMetadata(for: entry.item, source: source)
            var poster = metadata.item
            var title: String?
            if metadata.item.embyItemType == "Episode", let series = metadata.series {
                let parent = try? await library.seriesCatalog.detailMetadata(for: series, source: source)
                try Task.checkCancellation()
                poster = parent?.item ?? series
                var seasonCount = poster.embyPresentation?.seasonCount
                if seasonCount == nil {
                    seasonCount = try? await library.seriesCatalog.seriesSeasonCount(for: series, source: source)
                }
                try Task.checkCancellation()
                let multipleSeasons = (seasonCount ?? 0) > 1 || (metadata.seasonNumber ?? 0) > 1
                var episodeParts: [String] = []
                if let season = metadata.seasonNumber, multipleSeasons || season == 0 {
                    episodeParts.append(season == 0 ? VesperLocalization.string("特别篇") : VesperLocalization.localized("第\(season)季"))
                }
                if let episode = metadata.episodeNumber { episodeParts.append(VesperLocalization.localized("第\(episode)集")) }
                var lines = [series.title]
                if !episodeParts.isEmpty { lines.append(episodeParts.joined(separator: " · ")) }
                let episodeTitle = metadata.item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !episodeTitle.isEmpty, episodeTitle != series.title { lines.append(episodeTitle) }
                title = lines.joined(separator: " · ")
            } else if metadata.item.embyItemType == "Episode" {
                poster.embyItemType = "Movie"
            }
            try Task.checkCancellation()
            let value = HistoryArtworkCacheEntry(item: metadata.item, posterItem: poster, previewTitle: title)
            resolvedItem = value.item
            posterItem = value.posterItem
            previewTitle = value.previewTitle
            if let data = try? JSONEncoder().encode(value) {
                await AppCacheStore.shared.saveImageMetadata(data, key: cacheKey, generation: generation)
            }
        } catch {
            guard !Task.isCancelled, cached == nil else { return }
            var fallback = entry.item
            fallback.embyItemType = "Movie"
            posterItem = fallback
        }
    }
}
