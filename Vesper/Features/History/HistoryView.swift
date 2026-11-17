import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var library: SourceLibrary
    @EnvironmentObject private var playback: PlaybackSession
    @AppStorage("navigation.icons") private var icons = "{}"

    private var groups: [HistorySourceGroup] {
        Dictionary(grouping: playback.history, by: { $0.source.id }).values.map { entries in
            HistorySourceGroup(source: entries[0].source, entries: entries.sorted { $0.watchedAt > $1.watchedAt })
        }.sorted { left, right in
            if left.id == library.selectedID { return true }
            if right.id == library.selectedID { return false }
            return left.entries[0].watchedAt > right.entries[0].watchedAt
        }
    }

    var body: some View {
        if playback.history.isEmpty {
            VesperEmptyPage(title: "记录", message: "无记录", symbol: AppSection.history.symbol)
        } else {
            VesperRootScrollView(title: "记录") {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(verbatim: library.sources.first(where: { $0.id == group.id })?.name ?? group.source.name)
                                .font(.headline).foregroundStyle(.secondary)
                            ForEach(group.entries) { entry in
                                Button {
                                    let source = library.sources.first(where: { $0.id == group.id }) ?? group.source
                                    playback.play(entry.item, in: source, queue: group.entries.map(\.item))
                                } label: {
                                    HStack(spacing: 12) {
                                        MediaThumbnail(source: group.source, item: entry.item)
                                            .frame(width: 52, height: 78)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(verbatim: entry.title).font(.headline).lineLimit(2)
                                            Text(verbatim: "\(mediaTimeLabel(entry.position)) / \(mediaTimeLabel(entry.duration))")
                                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            Text(entry.watchedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "play.fill").foregroundStyle(.tint)
                                    }
                                    .padding(12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(Color("VesperSecondaryBackground"), in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

private struct HistorySourceGroup: Identifiable {
    let source: MediaSource
    let entries: [PlaybackHistoryEntry]
    var id: UUID { source.id }
}
