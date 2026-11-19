import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var library: SourceLibrary
    @EnvironmentObject private var playback: PlaybackSession
    @AppStorage("navigation.icons") private var icons = "{}"

    private var groups: [HistorySourceGroup] {
        Dictionary(grouping: playback.history.filter { $0.hiddenFromHistory != true }, by: { $0.source.id }).values.map { entries in
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
                            Text(verbatim: library.sources.first(where: { $0.id == group.id })?.name ?? group.source.name)
                                .font(.headline).foregroundStyle(.secondary)
                                .padding(.horizontal, 20)

                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 12) {
                                    ForEach(group.entries) { entry in
                                        let source = library.sources.first(where: { $0.id == group.id }) ?? group.source
                                        Button {
                                            playback.play(entry.item, in: source, queue: group.entries.map(\.item))
                                        } label: {
                                            MediaThumbnail(source: source, item: entry.item, playback: playback, historyEntry: entry,
                                                           usesMediaCardBackdrop: false)
                                                .frame(width: 132, height: 198)
                                        }
                                        .contentShape(Rectangle())
                                        .clipped()
                                        .buttonStyle(.plain)
                                        .modifier(MediaThumbnailMenu(source: source, item: entry.item, playback: playback, historyEntry: entry) { EmptyView() })
                                        .accessibilityLabel(Text(verbatim: entry.title))
                                    }
                                }
                                .scrollTargetLayout()
                                .padding(.vertical, 12)
                            }
                            .scrollIndicators(.hidden)
                            .contentMargins(.horizontal, 20, for: .scrollContent)
                            .scrollTargetBehavior(.viewAligned(anchor: .leading))
                        }
                    }
                }
            }
        }
        .onAppear { playback.pruneUnavailableHistory() }
    }
}

private struct HistorySourceGroup: Identifiable {
    let source: MediaSource
    let entries: [PlaybackHistoryEntry]
    var id: UUID { source.id }
}
