import Foundation

/// Serializes imports and keeps potentially large file copies off the main actor.
actor VideoImporter {
    static let shared = VideoImporter()
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]

    enum ImportFailure: LocalizedError {
        case unsupported, unreadable
        var errorDescription: String? {
            switch self {
            case .unsupported: "请选择支持的视频文件。"
            case .unreadable: "无法读取此视频，请先将文件下载到本机后重试。"
            }
        }
    }

    func importVideo(from incoming: URL) throws -> URL {
        guard incoming.isFileURL,
              Self.videoExtensions.contains(incoming.pathExtension.lowercased()) else {
            throw ImportFailure.unsupported
        }
        let scoped = incoming.startAccessingSecurityScopedResource()
        defer { if scoped { incoming.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        let documents = try manager.url(for: .documentDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let source = incoming.standardizedFileURL
        // Opening a video already in our library must not duplicate it.
        if source.deletingLastPathComponent() == documents.standardizedFileURL {
            guard manager.isReadableFile(atPath: source.path) else { throw ImportFailure.unreadable }
            return source
        }
        let staging = documents.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        var coordinationError: NSError?
        var copyError: Error?
        // Coordinates access with Files/iCloud and other document providers.
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                guard (try readable.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                    throw ImportFailure.unreadable
                }
                try manager.copyItem(at: readable, to: staging)
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var destination = documents.appendingPathComponent(source.lastPathComponent)
        var suffix = 2
        while manager.fileExists(atPath: destination.path) {
            destination = documents.appendingPathComponent("\(stem) (\(suffix)).\(ext)")
            suffix += 1
        }
        // Publish only a complete file; interrupted copies cannot appear as videos.
        try manager.moveItem(at: staging, to: destination)
        // iOS may deliver a private Inbox copy. External originals are never removed.
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL
        if source.deletingLastPathComponent() == inbox { try? manager.removeItem(at: source) }
        return destination
    }
}
