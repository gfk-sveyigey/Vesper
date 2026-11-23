import SwiftUI
import UIKit
import Network

struct MediaLibraryListRow: View {
    let source: MediaSource
    let item: MediaItem
    private let playback: PlaybackSession?
    private var transition: (id: EmbyMediaRoute, namespace: Namespace.ID)?
    @ObservedObject private var layout = MediaLayoutSettings.shared

    init(source: MediaSource, item: MediaItem, playback: PlaybackSession? = nil) {
        self.source = source
        self.item = item
        self.playback = playback
        self.transition = nil
    }

    init(source: MediaSource, item: MediaItem, transition: (id: EmbyMediaRoute, namespace: Namespace.ID)) {
        self.source = source
        self.item = item
        self.playback = nil
        self.transition = transition
    }

    private var kindKey: String {
        switch item.embyItemType {
        case "Movie": "电影"
        case "Series": "剧集"
        case "Episode": "单集"
        default: "视频"
        }
    }

    private var libraryListImageHeight: CGFloat {
        max(24, CGFloat(layout[.browserListRowHeight] - layout[.browserListImageTop] - layout[.browserListImageBottom]))
    }

    private var libraryListImageWidth: CGFloat { libraryListImageHeight * 2 / 3 }

    private var libraryListArtworkWidth: CGFloat {
        libraryListImageWidth + CGFloat(layout[.browserListImageLeading]) + CGFloat(layout[.browserListImageTrailing])
    }

    private let libraryListColumnSpacing: CGFloat = 12
    var dividerInset: CGFloat { libraryListArtworkWidth + libraryListColumnSpacing }

    var body: some View {
        let rowHeight = CGFloat(layout[.browserListRowHeight])
        let imageTop = CGFloat(layout[.browserListImageTop])
        let imageLeading = CGFloat(layout[.browserListImageLeading])
        let imageBottom = CGFloat(layout[.browserListImageBottom])
        let imageTrailing = CGFloat(layout[.browserListImageTrailing])
        let imageHeight = libraryListImageHeight
        let imageWidth = libraryListImageWidth
        let kind = VesperLocalization.string(kindKey)
        let genres = item.embyPresentation?.genres.prefix(3).joined(separator: " · ")
        let year = (source.kind == .emby ? item.subtitle : nil) ?? item.embyPresentation?.premiereDate.map {
            String(Calendar.current.component(.year, from: $0))
        } ?? "—"
        let rating = item.embyPresentation?.communityRating.map { String(format: "%.1f", $0) }
        let details = [kind, genres].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let yearAndRating = [year, rating.map { "★ \($0)" }].compactMap { $0 }.joined(separator: " · ")

        return HStack(spacing: libraryListColumnSpacing) {
            ZStack {
                MediaThumbnail(source: source, item: item, playback: playback, imageOrientation: .portrait,
                               fixedHeight: imageHeight, usesMediaCardBackdrop: source.kind == .emby)
                    .frame(width: imageWidth, height: imageHeight)
                    .mediaArtworkBorder()
                    .modifier(ListArtworkTransition(transition: transition))
                    .padding(.top, imageTop)
                    .padding(.leading, imageLeading)
                    .padding(.bottom, imageBottom)
                    .padding(.trailing, imageTrailing)
            }
            .frame(width: libraryListArtworkWidth, height: rowHeight)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: source.kind == .emby ? yearAndRating : item.subtitle ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct ListArtworkTransition: ViewModifier {
    let transition: (id: EmbyMediaRoute, namespace: Namespace.ID)?

    func body(content: Content) -> some View {
        if let transition {
            content.matchedTransitionSource(id: transition.id, in: transition.namespace)
        } else {
            content
        }
    }
}
