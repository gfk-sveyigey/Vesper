import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class PlayerDanmaku: ObservableObject {
    @Published var comments: [DanmakuComment] = [] { didSet { revision += 1 } }
    @Published private(set) var revision = 0
    @Published var filename: String?
    @Published var offset: Double = 0
    @Published private(set) var isImporting = false

    func importFile(_ url: URL) async throws {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let parsed = try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
            return try DanmakuXMLParser.parse(data)
        }.value
        try Task.checkCancellation()
        comments = parsed; filename = url.lastPathComponent; offset = 0
    }
}

struct DanmakuOverlay: View {
    @ObservedObject var session: PlaybackSession
    @ObservedObject var document: PlayerDanmaku
    private var preferences = DanmakuPreferences()
    @State private var positions: [DanmakuPlacement] = []
    @State private var anchor = Date()
    private var size: CGFloat { CGFloat(min(40, max(14, preferences.fontSize))) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if preferences.enabled && !positions.isEmpty && !session.isPictureInPictureActive {
                    // An empty overlay must not start a separate animation clock when
                    // playback begins. Active comments follow the scene's UI cadence.
                    TimelineView(.animation(paused: !session.isPlaying || session.isSeeking || session.isLoading)) { timeline in
                        Canvas { context, bounds in
                            guard preferences.enabled, !session.isPictureInPictureActive else { return }
                            let elapsed = session.isPlaying && !session.isSeeking && !session.isLoading
                                ? min(0.5, max(0, timeline.date.timeIntervalSince(anchor))) * Double(session.playbackRate) : 0
                            let time = session.currentTime + elapsed - document.offset
                            // Binary search bounds the work to the short active window, not the entire file.
                            var low = 0, high = positions.count
                            while low < high {
                                let mid = (low + high) / 2
                                if positions[mid].comment.time < time - 20 { low = mid + 1 } else { high = mid }
                            }
                            for entry in positions[low...] {
                                let age = time - entry.comment.time
                                if age < 0 { break }
                                guard age < entry.lifetime else { continue }
                                let c = preferences.colored ? entry.comment.color : 0xFFFFFF
                                let color = Color(red: Double((c >> 16) & 255) / 255, green: Double((c >> 8) & 255) / 255, blue: Double(c & 255) / 255)
                                let label = Text(entry.comment.text).font(.system(size: size, weight: preferences.bold ? .bold : .regular)).foregroundColor(color)
                                let x = entry.scrolling
                                    ? bounds.width - CGFloat(age / entry.lifetime) * (bounds.width + CGFloat(entry.width)) + CGFloat(entry.width) / 2
                                    : bounds.width / 2
                                var shaded = context
                                if preferences.shadow {
                                    shaded.addFilter(.shadow(color: .black.opacity(0.95), radius: 1, x: 1, y: 1))
                                }
                                shaded.draw(label, at: CGPoint(x: x, y: CGFloat(entry.y)))
                            }
                        }
                    }
                }
            }
            .task(id: "\(geometry.size.width)-\(geometry.size.height)-\(preferences.layoutKey)-\(document.revision)") {
                layout(in: geometry.size)
            }
        }
        .opacity(min(1, max(0.1, preferences.opacity)))
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: session.currentTime) { _, _ in anchor = Date() }
        .onChange(of: session.isPlaying) { _, _ in anchor = Date() }
    }

    private func layout(in bounds: CGSize) {
        positions = DanmakuLayout.build(comments: document.comments, width: Double(bounds.width),
                                        height: Double(bounds.height), options: preferences.options) { text in
            Double((text as NSString).size(withAttributes: [
                .font: UIFont.systemFont(ofSize: size, weight: preferences.bold ? .bold : .regular)
            ]).width)
        }
    }
}

struct PlayerDanmakuSettingsView: View {
    @ObservedObject var document: PlayerDanmaku
    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "弹幕设置", symbol: "text.bubble", description: "调整当前弹幕的时间偏移与显示偏好。")
            SettingsSection("当前视频弹幕") {
                if let filename = document.filename {
                    Text(filename)
                    Text(String(format: VesperLocalization.string("%lld 条弹幕"), document.comments.count)).foregroundStyle(.secondary)
                    Stepper(value: $document.offset, in: -600...600, step: 0.5) {
                        Text(String(format: VesperLocalization.string("时间偏移：%.1f 秒"), document.offset))
                    }
                    Button("移除当前弹幕", role: .destructive) {
                        document.comments = []; document.filename = nil; document.offset = 0
                    }
                } else {
                    Text("尚未加载弹幕").foregroundStyle(.secondary)
                }
            } footer: {
                Text("从进度条上方的多功能菜单搜索或导入弹幕。支持 Bilibili XML 的滚动、顶部和底部弹幕。正偏移表示延后显示。弹幕仅用于当前视频，切换视频后清空；画中画暂不显示弹幕。")
            }
            DanmakuPreferenceSections()
        }
        .navigationTitle("弹幕设置")
        .toolbarTitleDisplayMode(.inline)
    }
}
