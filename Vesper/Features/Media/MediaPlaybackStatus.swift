import SwiftUI
import UIKit

/// Only persisted progress is shown, and only while progress retention is enabled.
struct ThumbnailPlaybackProgress: View {
    @ObservedObject var session: PlaybackSession
    let source: MediaSource
    let item: MediaItem
    @AppStorage("player.rememberProgress") private var remembersProgress = true
    @State private var duration: Double = 0
    private var progress: Double {
        guard remembersProgress else { return 0 }
        return session.resumePosition(for: item)
    }
    private var total: Double { duration > 0 ? duration : session.savedDuration(for: item) }
    var body: some View {
        Group {
            if progress > 0 && total > 0 {
                ThumbnailProgressBadge(position: progress, total: total)
            }
        }
        .task(id: progress > 0 ? item.id : nil) {
            guard progress > 0 else { return }
            let result = await MediaThumbnailLoader.shared.duration(item, source: source)
            guard !Task.isCancelled else { return }
            duration = result
        }
    }
}

struct MediaPlaybackStatus: View {
    let position: Double
    let duration: Double?
    var played = false

    var body: some View {
        HStack(spacing: 7) {
            if played {
                Image(systemName: "arrow.clockwise").accessibilityLabel("已观看")
            } else if position.isFinite && position > 0 {
                Image(systemName: "play.fill").accessibilityLabel("有播放进度")
                if let duration, duration.isFinite, duration > 0 {
                    ProgressView(value: min(position / duration, 1)).frame(width: 38)
                }
            }
            if let duration, duration.isFinite, duration > 0 {
                Text(verbatim: mediaTimeLabel(duration)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
            } else {
                Text("未知时长").lineLimit(1)
            }
        }
    }
}

struct ThumbnailProgressBadge: View {
    let position: Double
    let total: Double
    @ScaledMetric(relativeTo: .caption2) private var progressWidth = 20.0
    private var fraction: CGFloat {
        guard total.isFinite, position.isFinite, total > 0 else { return 0 }
        return CGFloat(min(1, max(0, position / total)))
    }
    var body: some View {
        HStack(spacing: 5) {
            if total > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.35))
                        Capsule().fill(.white)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geometry.size.width * fraction)
                            }
                    }
                }
                .frame(width: progressWidth, height: 4)
            }
            Text(verbatim: mediaTimeLabel(total))
                .font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.bottom, 8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottomLeading)
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                }
                .mask {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                }
                .environment(\.colorScheme, .dark)
        }
    }
}

/// Ignore degraded previews and resume exactly once, including cancellation.
