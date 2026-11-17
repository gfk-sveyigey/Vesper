import Foundation
import Combine

/// Keeps the original file accessible across inspection, sheet presentation and
/// direct playback. Access ends only when the last owner releases the file.
final class IncomingFileAccess: Sendable {
    let url: URL
    private let scoped: Bool
    private let temporaryDirectory: URL?
    var hasSecurityScope: Bool { scoped }

    init(url: URL, temporaryDirectory: URL? = nil) {
        self.url = url
        self.temporaryDirectory = temporaryDirectory
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
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

/// The native scene delegate and SwiftUI use the same receiver, including
/// delivery before the root view appears.
@MainActor
final class IncomingVideoReceiver: ObservableObject {
    static let shared = IncomingVideoReceiver()
    @Published private(set) var videos: [IncomingVideo] = []
    @Published private(set) var nonVideoCount = 0
    private struct Request {
        let access: IncomingFileAccess
        let requiresCopy: Bool
    }
    private var requests: [Request] = []
    private var isInspecting = false

    func receive(_ url: URL, requiresCopy: Bool) {
        // Acquire sandbox access synchronously in the system's URL callback.
        let access = IncomingFileAccess(url: url)
        requests.append(Request(access: access, requiresCopy: requiresCopy))
        log("收到文件 URL，scheme=\(url.scheme ?? "nil") extension=\(url.pathExtension) scoped=\(access.hasSecurityScope) requiresCopy=\(requiresCopy)")
        inspectNext()
    }

    func takeNext() -> IncomingVideo? {
        guard !videos.isEmpty else { return nil }
        return videos.removeFirst()
    }

    private func inspectNext() {
        guard !isInspecting, !requests.isEmpty else { return }
        isInspecting = true
        let request = requests.removeFirst()
        Task {
            defer {
                isInspecting = false
                inspectNext()
            }
            let access: IncomingFileAccess
            do {
                access = try await VideoImporter.shared.prepare(request.access, requiresCopy: request.requiresCopy)
                if request.requiresCopy { log("临时副本准备完成，开始视频检查") }
            } catch {
                log("文件不可读取或临时复制失败，忽略：\(error.localizedDescription)")
                return
            }
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
        }
    }

    private func log(_ message: String) {
        AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [VideoImport] \(message)")
    }
}
