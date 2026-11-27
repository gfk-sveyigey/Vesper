import SwiftUI
import UIKit
import Network

struct MediaLibraryListRow: View {
    let source: MediaSource
    let item: MediaItem
    private let playback: PlaybackSession?
    private var transition: (id: EmbyMediaRoute, namespace: Namespace.ID)?
    @ObservedObject private var layout = MediaLayoutSettings.shared

    init(source: MediaSource, item: MediaItem, playback: PlaybackSession? = nil,
         transition: (id: EmbyMediaRoute, namespace: Namespace.ID)? = nil) {
        self.source = source
        self.item = item
        self.playback = playback
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

    var dividerInset: CGFloat { MediaLibraryListRowGeometry(layout: layout).dividerInset }

    var body: some View {
        let kind = VesperLocalization.string(kindKey)
        let genres = item.embyPresentation?.genres.prefix(3).joined(separator: " · ")
        let year = (source.kind == .emby ? item.subtitle : nil) ?? item.embyPresentation?.premiereDate.map {
            String(Calendar.current.component(.year, from: $0))
        } ?? "—"
        let rating = item.embyPresentation?.communityRating.map { String(format: "%.1f", $0) }
        let details = [kind, genres].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let yearAndRating = [year, rating.map { "★ \($0)" }].compactMap { $0 }.joined(separator: " · ")

        return MediaLibraryListRowLayout(layout: layout) { imageSize in
            MediaThumbnail(source: source, item: item, playback: playback, imageOrientation: .portrait,
                           fixedHeight: imageSize.height, usesMediaCardBackdrop: source.kind == .emby)
                .frame(width: imageSize.width, height: imageSize.height)
                .mediaArtworkBorder()
                .modifier(ListArtworkTransition(transition: transition))
        } details: {
            Text(verbatim: item.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            if source.kind == .emby {
                Text(verbatim: details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: yearAndRating)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                DeviceListVideoMetadata(source: source, item: item)
            }
        }
    }
}

@MainActor
private struct MediaLibraryListRowGeometry {
    let layout: MediaLayoutSettings
    let columnSpacing: CGFloat = 12

    var rowHeight: CGFloat { CGFloat(layout[.browserListRowHeight]) }
    var imageTop: CGFloat { CGFloat(layout[.browserListImageTop]) }
    var imageLeading: CGFloat { CGFloat(layout[.browserListImageLeading]) }
    var imageBottom: CGFloat { CGFloat(layout[.browserListImageBottom]) }
    var imageTrailing: CGFloat { CGFloat(layout[.browserListImageTrailing]) }
    var imageHeight: CGFloat { max(24, rowHeight - imageTop - imageBottom) }
    var imageWidth: CGFloat { imageHeight * 2 / 3 }
    var imageSize: CGSize { CGSize(width: imageWidth, height: imageHeight) }
    var artworkWidth: CGFloat { imageWidth + imageLeading + imageTrailing }
    var dividerInset: CGFloat { artworkWidth + columnSpacing }
}

struct MediaLibraryListRowLayout<Artwork: View, Details: View>: View {
    let layout: MediaLayoutSettings
    @ViewBuilder let artwork: (CGSize) -> Artwork
    @ViewBuilder let details: () -> Details

    var body: some View {
        let geometry = MediaLibraryListRowGeometry(layout: layout)
        HStack(spacing: geometry.columnSpacing) {
            ZStack {
                artwork(geometry.imageSize)
                    .frame(width: geometry.imageWidth, height: geometry.imageHeight)
                    .padding(.top, geometry.imageTop)
                    .padding(.leading, geometry.imageLeading)
                    .padding(.bottom, geometry.imageBottom)
                    .padding(.trailing, geometry.imageTrailing)
            }
            .frame(width: geometry.artworkWidth, height: geometry.rowHeight)

            VStack(alignment: .leading, spacing: 4, content: details)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: geometry.rowHeight, maxHeight: geometry.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct DeviceListVideoMetadata: View {
    let source: MediaSource
    let item: MediaItem
    @State private var metadata: (duration: Double, byteCount: Int?) = (0, nil)

    var body: some View {
        let duration = metadata.duration.isFinite && metadata.duration > 0 ? mediaTimeLabel(metadata.duration) : "—"
        let size = metadata.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
        HStack(spacing: 6) {
            Text(verbatim: duration)
                .monospacedDigit()
                .accessibilityLabel("时长")
                .accessibilityValue(Text(verbatim: duration))
            Text(verbatim: "·").accessibilityHidden(true)
            Text(verbatim: size)
                .accessibilityLabel("文件大小")
                .accessibilityValue(Text(verbatim: size))
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .task(id: item) {
            metadata = (0, nil)
            let result = await MediaThumbnailLoader.shared.deviceListMetadata(item, source: source)
            if !Task.isCancelled { metadata = result }
        }
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
