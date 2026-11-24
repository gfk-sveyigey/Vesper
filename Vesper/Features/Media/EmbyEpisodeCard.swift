import SwiftUI
import UIKit

struct EmbyEpisodeCard: View {
    let source: MediaSource
    let episode: EmbyEpisode
    let width: CGFloat
    let height: CGFloat
    let position: Double
    let isBusy: Bool
    let isSelected: Bool
    let open: () -> Void
    let clear: () -> Void
    let setPlayed: (Bool) -> Void

    @EnvironmentObject private var playback: PlaybackSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedArtwork: EpisodeArtwork?

    private struct EpisodeArtwork {
        let key: String
        let image: UIImage?
    }

    private var artworkKey: String {
        "\(AppCacheStore.embyArtworkKey(for: episode.item, source: source))|landscape"
    }

    private var artwork: EpisodeArtwork? {
        loadedArtwork?.key == artworkKey ? loadedArtwork : nil
    }

    private var title: String { episode.displayTitle }
    private var showsEpisodeNumber: Bool { episode.displayTitle != episode.numberLabel }

    var body: some View {
        let showsMissingArtwork = artwork != nil && artwork?.image == nil

        MediaCardBackdrop(showsMissingArtwork: showsMissingArtwork, iconCenterY: 1.0 / 3)
        .frame(width: width, height: height)
        .overlay {
            EmbyEpisodeArtworkSurface(image: artwork?.image, size: CGSize(width: width, height: height))
        }
        .overlay(alignment: .bottomLeading) { details }
        .overlay(alignment: .bottomTrailing) { moreButton.padding(.trailing, 10).padding(.bottom, 10) }
        .mediaArtworkBorder(cornerRadius: 16, isSelected: isSelected)
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
            if loadedArtwork?.key == key { return }
            let data = await MediaThumbnailLoader.shared.load(episode.item, source: source,
                                                              imageOrientation: .landscape)
            guard !Task.isCancelled else { return }
            let image = data.flatMap { UIImage(data: $0) }
            loadedArtwork = EpisodeArtwork(key: key, image: image)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsEpisodeNumber {
                Text(verbatim: episode.numberLabel).font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Text(verbatim: episode.item.embyPresentation?.overview ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
            playbackRow
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: height * 0.5, alignment: .bottomLeading)
        .offset(y: 4)
    }

    private var playbackRow: some View {
        HStack(spacing: 7) {
            MediaPlaybackStatus(position: position, duration: episode.item.duration, played: effectivePlayed)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var moreButton: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多操作")
    }

    @ViewBuilder
    private var actions: some View {
        Button("前往单集", systemImage: "info.circle", action: open)
        if position > 0 {
            Button("清除播放进度", systemImage: "clock.arrow.circlepath", action: clear)
                .disabled(isBusy || (playback.resumePosition(for: episode.item) > 0 && source.emby?.userID == nil))
        }
        let played = effectivePlayed
        Button(played ? "标记为未观看" : "标记为已观看",
               systemImage: played ? "circle" : "checkmark.circle") {
            setPlayed(!played)
        }
        .disabled(!playback.canSetPlayed(for: source))
    }

    private var effectivePlayed: Bool {
        playback.effectivePlayed(for: episode.item)
    }
}


// Shared image fill and bottom-edge extension for episode cards and detail heroes.
struct EmbyEpisodeArtworkSurface: View {
    let image: UIImage?
    let size: CGSize
    @Environment(\.colorScheme) private var colorScheme

    private var bottomStrip: UIImage? {
        guard let cgImage = image?.cgImage else { return nil }
        let depth = max(1, cgImage.height / 6)
        return cgImage.cropping(to: CGRect(x: 0, y: cgImage.height - depth,
                                          width: cgImage.width, height: depth))
            .map { UIImage(cgImage: $0) }
    }

    var body: some View {
        if let image {
            let artworkHeight = size.width * image.size.height / max(1, image.size.width)
            let blendStart = min(size.height * 0.38, max(0, artworkHeight - 32))
            let blurHeight = size.height - blendStart
            ZStack(alignment: .top) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: size.width, height: artworkHeight)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .clipped()
                ZStack {
                    if let bottomStrip {
                        Image(uiImage: bottomStrip).resizable()
                            .frame(width: size.width + 44, height: blurHeight + 44)
                            .blur(radius: 22)
                    }
                    (colorScheme == .dark ? Color.black.opacity(0.66) : Color.white.opacity(0.74))
                }
                .frame(width: size.width, height: blurHeight)
                .clipped()
                .mask {
                    LinearGradient(colors: [.clear, .black], startPoint: .top,
                                   endPoint: UnitPoint(x: 0.5, y: min(1, 45 / max(1, blurHeight))))
                }
                .offset(y: blendStart)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .allowsHitTesting(false)
        }
    }
}
