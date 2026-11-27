import Foundation
import Combine

/// Keeps the original file accessible across inspection, sheet presentation and
/// direct playback. Access ends only when the last owner releases the file.
final class IncomingFileAccess: Sendable {
    let url: URL
    private let scoped: Bool
    private let temporaryDirectory: URL?
    private let sharedBatch: SharedVideoBatchAccess?
    var hasSecurityScope: Bool { scoped }

    init(url: URL, temporaryDirectory: URL? = nil, sharedBatch: SharedVideoBatchAccess? = nil) {
        self.url = url
        self.temporaryDirectory = temporaryDirectory
        self.sharedBatch = sharedBatch
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }
}

/// Keep the published batch on disk until its last preview or playback releases it.
final class SharedVideoBatchAccess: Sendable {
    let directory: URL
    private let lease: SharedVideoBatchLease

    init?(directory: URL) {
        guard let lease = SharedVideoBatchLease(directory) else { return nil }
        self.directory = directory
        self.lease = lease
    }

    deinit {
        withExtendedLifetime(lease) { try? FileManager.default.removeItem(at: directory) }
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
    let automaticallySaves: Bool
    let unreadableFileNames: [String]

    init(files: [IncomingVideo], automaticallySaves: Bool = false, unreadableFileNames: [String] = []) {
        self.files = files
        self.automaticallySaves = automaticallySaves || files.count > 1
        self.unreadableFileNames = unreadableFileNames
    }
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
    private var openedSharedBatches: Set<URL> = []

    func receiveSharedBatches(from root: URL? = SharedVideoInbox.root) async {
        guard let root else { return }
        for directory in SharedVideoInbox.batches(in: root) {
            guard !openedSharedBatches.contains(directory),
                  let batch = SharedVideoBatchAccess(directory: directory) else { continue }
            openedSharedBatches.insert(directory)
            let urls = SharedVideoInbox.files(in: directory)
            log("分享扩展交付文件数=\(urls.count)")
            let files = urls.map { IncomingFileAccess(url: $0, sharedBatch: batch) }
            await inspectDeliveredBatch(files)
        }
    }

    func receive(_ url: URL, requiresCopy: Bool) {
        // Acquire sandbox access synchronously in the system's URL callback.
        receive(IncomingFileAccess(url: url), requiresCopy: requiresCopy)
    }

    func receivePickedFiles(_ files: [IncomingFileAccess]) {
        guard !files.isEmpty else { return }
        log("文件选择器交付文件数=\(files.count)")
        // Start with the copies retained by the delegate, before the sheet closes.
        Task { await inspectDeliveredBatch(files) }
    }

    private func inspectDeliveredBatch(_ files: [IncomingFileAccess]) async {
        let automaticallySaves = files.count > 1
        var videos: [IncomingVideo] = []
        var unreadableFileNames: [String] = []
        var invalidCount = 0
        for access in files {
            switch await VideoImporter.shared.inspect(access) {
            case .video(let video):
                videos.append(video)
            case .notVideo:
                invalidCount += 1
            case .unreadable:
                unreadableFileNames.append(access.url.lastPathComponent)
            }
        }
        log("文件检查结束，视频=\(videos.count)，非视频=\(invalidCount)，不可读取=\(unreadableFileNames.count)")
        if !videos.isEmpty || (automaticallySaves && !unreadableFileNames.isEmpty) {
            batches.append(IncomingVideoBatch(files: videos, automaticallySaves: automaticallySaves,
                                              unreadableFileNames: unreadableFileNames))
        }
        if invalidCount > 0 { nonVideoCount += invalidCount }
    }

    private func receive(_ access: IncomingFileAccess, requiresCopy: Bool) {
        let url = access.url
        requests.append(Request(access: access, requiresCopy: requiresCopy))
        publishTask?.cancel()
        log("收到文件 URL，scheme=\(url.scheme ?? "nil") extension=\(url.pathExtension) scoped=\(access.hasSecurityScope) requiresCopy=\(requiresCopy)")
        inspectNext()
    }

    /// Remove a batch once its preview is visible or automatic saving owns its files.
    func acknowledgeBatch(_ id: UUID) {
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
                log("视频检查通过，加入导入队列")
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
