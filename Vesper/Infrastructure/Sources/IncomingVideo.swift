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

struct IncomingVideoBatch: Identifiable, Sendable {
    let id = UUID()
    let files: [IncomingVideo]
}

/// The application delegate and SwiftUI use the same receiver, including
/// delivery before the root view appears.
@MainActor
final class IncomingVideoReceiver: ObservableObject {
    static let shared = IncomingVideoReceiver()
    @Published private(set) var batches: [IncomingVideoBatch] = []
    @Published private(set) var nonVideoCount = 0
    @Published var isSelectingVideo = false

    func selectVideo() {
        guard !isSelectingVideo else { return }
        log("请求由根页面打开视频文件选择器")
        isSelectingVideo = true
    }
    private struct Request {
        let access: IncomingFileAccess
        let requiresCopy: Bool
    }
    private var requests: [Request] = []
    private var isInspecting = false
    private var inspectedVideos: [IncomingVideo] = []
    private var inspectedNonVideoCount = 0
    private var publishTask: Task<Void, Never>?

    func receive(_ url: URL, requiresCopy: Bool) {
        // Acquire sandbox access synchronously in the system's URL callback.
        let access = IncomingFileAccess(url: url)
        requests.append(Request(access: access, requiresCopy: requiresCopy))
        publishTask?.cancel()
        log("收到文件 URL，scheme=\(url.scheme ?? "nil") extension=\(url.pathExtension) scoped=\(access.hasSecurityScope) requiresCopy=\(requiresCopy)")
        inspectNext()
    }

    /// Reserve by peeking; only acknowledge after the import sheet appears.
    /// A rejected/background presentation must not silently lose the file.
    func acknowledgePresented(_ id: UUID) {
        batches.removeAll { $0.id == id }
    }

    private func inspectNext() {
        guard !isInspecting else { return }
        guard !requests.isEmpty else {
            publishWhenDeliverySettles()
            return
        }
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
                inspectedNonVideoCount += 1
            case .video(let file):
                log("视频检查通过，等待用户选择操作")
                inspectedVideos.append(file)
            }
        }
    }

    private func publishWhenDeliverySettles() {
        guard !inspectedVideos.isEmpty || inspectedNonVideoCount > 0 else { return }
        // Open In can deliver a single selection as several separate URL callbacks.
        publishTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            if !inspectedVideos.isEmpty {
                batches.append(IncomingVideoBatch(files: inspectedVideos))
                inspectedVideos.removeAll()
            }
            if inspectedNonVideoCount > 0 {
                nonVideoCount += inspectedNonVideoCount
                inspectedNonVideoCount = 0
            }
            publishTask = nil
        }
    }

    private func log(_ message: String) {
        AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [VideoImport] \(message)")
    }
}
