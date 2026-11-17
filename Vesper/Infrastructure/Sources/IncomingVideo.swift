import Foundation
import Combine

/// Keeps the original file accessible across inspection, sheet presentation and
/// direct playback. Access ends only when the last owner releases the file.
final class IncomingFileAccess: Sendable {
    let url: URL
    private let scoped: Bool

    init(url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}

struct IncomingVideo: Identifiable, Sendable {
    let id = UUID()
    let access: IncomingFileAccess
    let duration: TimeInterval?
    let width: Int
    let height: Int
    let byteCount: Int64?
    var url: URL { access.url }
    var name: String { url.lastPathComponent }
}

/// App-level receiver retains incoming URLs even before the root view appears.
@MainActor
final class IncomingVideoReceiver: ObservableObject {
    @Published private(set) var videos: [IncomingVideo] = []
    @Published private(set) var nonVideoCount = 0
    private var requests: [IncomingFileAccess] = []
    private var isInspecting = false

    func receive(_ url: URL) {
        // Acquire sandbox access synchronously in the system's URL callback.
        let access = IncomingFileAccess(url: url)
        requests.append(access)
        log("收到文件 URL，scheme=\(url.scheme ?? "nil") extension=\(url.pathExtension)")
        inspectNext()
    }

    func takeNext() -> IncomingVideo? {
        guard !videos.isEmpty else { return nil }
        return videos.removeFirst()
    }

    private func inspectNext() {
        guard !isInspecting, !requests.isEmpty else { return }
        isInspecting = true
        let access = requests.removeFirst()
        Task {
            switch await VideoImporter.shared.inspect(access) {
            case .unreadable:
                // User requested no UI or library changes for unreadable files.
                log("文件不可读取，忽略")
            case .notVideo:
                log("可读取文件中未发现视频流")
                nonVideoCount += 1
            case .video(let file):
                log("视频检查通过，等待用户选择操作")
                videos.append(file)
            }
            isInspecting = false
            inspectNext()
        }
    }

    private func log(_ message: String) {
        AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [VideoImport] \(message)")
    }
}
