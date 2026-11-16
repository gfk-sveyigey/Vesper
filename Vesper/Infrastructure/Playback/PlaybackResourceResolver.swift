import Foundation
@preconcurrency import Photos

/// Owns access to a URL until playback stops, including security scope and
/// downloaded Photos files. Never release these when the player sheet closes.
@MainActor
final class ResolvedPlaybackResource {
    let url: URL
    private let scopedFolder: URL?
    private let temporary: Bool

    init(url: URL, scopedFolder: URL? = nil, temporary: Bool = false) {
        self.url = url
        self.scopedFolder = scopedFolder
        self.temporary = temporary
    }

    func release() {
        scopedFolder?.stopAccessingSecurityScopedResource()
        if temporary { try? FileManager.default.removeItem(at: url) }
    }
}

enum PlaybackFailure: LocalizedError {
    case missingFile, unavailableAsset, demo
    var errorDescription: String? {
        switch self {
        case .missingFile: "视频文件不存在或无法访问。"
        case .unavailableAsset: "无法读取相册视频，请检查照片权限和网络连接。"
        case .demo: "演示内容无法播放。"
        }
    }
}

@MainActor
struct PlaybackResourceResolver {
    func resolve(_ item: MediaItem, source: MediaSource) async throws -> ResolvedPlaybackResource {
        guard item.id.sourceID == source.id else { throw PlaybackFailure.missingFile }
        switch source.kind {
        case .demo:
            throw PlaybackFailure.demo
        case .local:
            let folder = try source.localFolderURL()
            let scoped = folder.startAccessingSecurityScopedResource()
            let file = folder.appendingPathComponent(item.id.localID)
            guard file.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  FileManager.default.isReadableFile(atPath: file.path) else {
                if scoped { folder.stopAccessingSecurityScopedResource() }
                throw PlaybackFailure.missingFile
            }
            return ResolvedPlaybackResource(url: file, scopedFolder: scoped ? folder : nil)
        case .photos:
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id.localID], options: nil).firstObject else {
                throw PlaybackFailure.unavailableAsset
            }
            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video }) else { throw PlaybackFailure.unavailableAsset }
            // Materialize the original/full-size resource: Photos may return a
            // composition instead of an AVURLAsset, and iCloud files need downloading.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Vesper-playback-\(UUID().uuidString)")
                .appendingPathExtension((resource.originalFilename as NSString).pathExtension)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                try Task.checkCancellation()
                return ResolvedPlaybackResource(url: url, temporary: true)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }
}

extension MediaSource {
    func localFolderURL() throws -> URL {
        if let bookmark = folderBookmark {
            var stale = false
            return try URL(resolvingBookmarkData: bookmark, options: [], bookmarkDataIsStale: &stale)
        }
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw PlaybackFailure.missingFile
        }
        return url
    }
}
