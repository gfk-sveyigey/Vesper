import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class PlayerDanmaku: ObservableObject {
    @Published var comments: [DanmakuComment] = [] { didSet { revision += 1 } }
    @Published private(set) var revision = 0
    @Published var filename: String?
    @Published var offset: Double = 0
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
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !session.isPlaying || !preferences.enabled || session.isPictureInPictureActive)) { timeline in
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
    @State private var importing = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Form {
            DanmakuPreferenceSections()
            Section {
                NavigationLink("搜索在线弹幕") { DanmakuAPISearchView(document: document) }
                    .disabled(loading)
                Button(loading ? "正在导入…" : "导入本地弹幕文件") { importing = true }.disabled(loading)
                if let filename = document.filename {
                    Text(filename)
                    Text("\(document.comments.count) 条弹幕").foregroundStyle(.secondary)
                    Stepper(value: $document.offset, in: -600...600, step: 0.5) {
                        Text("时间偏移：\(document.offset, specifier: "%.1f") 秒")
                    }
                    Button("移除当前弹幕", role: .destructive) {
                        document.comments = []; document.filename = nil; document.offset = 0
                    }
                }
            } footer: {
                Text("支持 Bilibili XML 的滚动、顶部和底部弹幕。正偏移表示延后显示。弹幕仅用于当前视频，切换视频后清空；画中画暂不显示弹幕。")
            }
        }
        .navigationTitle("弹幕设置")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.xml]) { result in
            switch result {
            case .failure(let failure): error = failure.localizedDescription
            case .success(let url):
                loading = true
                Task { @MainActor in
                    do {
                        let comments = try await Task.detached(priority: .userInitiated) {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            let values = try url.resourceValues(forKeys: [.fileSizeKey])
                            guard (values.fileSize ?? 0) <= 16 * 1024 * 1024 else { throw DanmakuImportError.tooLarge }
                            let handle = try FileHandle(forReadingFrom: url)
                            defer { try? handle.close() }
                            let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
                            return try DanmakuXMLParser.parse(data)
                        }.value
                        document.comments = comments; document.filename = url.lastPathComponent; document.offset = 0
                    } catch { self.error = error.localizedDescription }
                    loading = false
                }
            }
        }
        .alert("弹幕导入失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}
