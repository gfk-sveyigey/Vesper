import SwiftUI
import UIKit
import Network

struct RecentEmbyPlaybackCard: View {
    let source: MediaSource
    let entry: PlaybackHistoryEntry
    let open: (MediaItem) -> Void
    let clear: (MediaItem) -> Void
    let setPlayed: (MediaItem, Bool) -> Void

    @EnvironmentObject private var playback: PlaybackSession
    @EnvironmentObject private var library: SourceLibrary
    @State private var item: MediaItem
    @State private var title: String

    init(source: MediaSource, entry: PlaybackHistoryEntry,
         open: @escaping (MediaItem) -> Void, clear: @escaping (MediaItem) -> Void,
         setPlayed: @escaping (MediaItem, Bool) -> Void) {
        self.source = source
        self.entry = entry
        self.open = open
        self.clear = clear
        self.setPlayed = setPlayed
        _item = State(initialValue: entry.item)
        _title = State(initialValue: entry.title)
    }

    var body: some View {
        cardArtwork
            .onTapGesture { open(item) }
            .overlay(alignment: .bottomTrailing) {
                episodeMenu.padding(.trailing, 10).padding(.bottom, 10)
            }
            .contextMenu {
                playbackActions
            } preview: {
                MediaThumbnailPreview(source: source, item: item, historyEntry: entry,
                                      previewTitle: title, usesLandscapeArtwork: true)
            }
            .task(id: "\(source.id)|\(entry.mediaID.localID)") {
                do {
                    let details = try await library.catalog.detailMetadata(for: entry.item, source: source)
                    guard !Task.isCancelled else { return }
                    item = details.item
                    if details.item.embyItemType == "Episode", let series = details.series {
                        var seasonCount = series.embyPresentation?.seasonCount
                        if seasonCount == nil {
                            seasonCount = try? await library.catalog.seriesSeasonCount(for: series, source: source)
                        }
                        guard !Task.isCancelled else { return }
                        let count = seasonCount ?? 1
                        var parts = [series.title]
                        if count > 1, let season = details.seasonNumber {
                            parts.append(VesperLocalization.localized("第\(season)季"))
                        }
                        if let number = details.episodeNumber {
                            parts.append(VesperLocalization.localized("第\(number)集"))
                        }
                        title = parts.joined(separator: " · ")
                    } else {
                        title = details.item.title
                    }
                } catch { }
            }
    }

    private var cardArtwork: some View {
        MediaThumbnail(source: source, item: item, aspectRatio: 1.5, imageOrientation: .landscape,
                       allowsRemotePrimary: false, prefersLandscapeMovieArtwork: true,
                       bottomArtworkBlur: 4)
            .frame(width: 246, height: 164)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    MediaPlaybackStatus(position: entry.position, duration: entry.duration,
                                        played: playback.effectivePlayed(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .shadow(color: Color(uiColor: .systemBackground).opacity(0.85), radius: 2)
                .padding(.leading, 12)
                .padding(.trailing, 50)
                .padding(.bottom, 5)
            }
            .mediaArtworkBorder()
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var playbackActions: some View {
        Button(item.embyItemType == "Episode" ? "前往单集" : "详情", systemImage: "info.circle") { open(item) }
        if entry.position > 0 {
            Button("清除播放进度", systemImage: "clock.arrow.circlepath") { clear(item) }
        }
        let played = playback.effectivePlayed(for: item)
        Button(played ? "标记为未观看" : "标记为已观看",
               systemImage: played ? "circle" : "checkmark.circle") {
            setPlayed(item, !played)
        }
    }

    private var episodeMenu: some View {
        Menu {
            playbackActions
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多操作")
    }
}
