import Foundation
@preconcurrency import Photos
import PlaybackContracts

/// Owns access to a URL until playback stops, including security scope and
/// downloaded Photos files. Never release these when the player sheet closes.
@MainActor
final class ResolvedPlaybackResource {
    let url: URL
    let headers: [String: String]
    let embyPlaySessionID: String?
    let embyItemID: String?
    let embyMediaSourceID: String?
    let embyUserID: String?
    let duration: Double?
    let resumePosition: Double?
    let externalSubtitles: [EngineExternalSubtitle]
    private let scopedFolder: URL?
    private let temporary: Bool
    private var externalAccess: IncomingFileAccess?

    init(url: URL, headers: [String: String] = [:], embyPlaySessionID: String? = nil,
         embyItemID: String? = nil, embyMediaSourceID: String? = nil, embyUserID: String? = nil,
         duration: Double? = nil, resumePosition: Double? = nil,
         externalSubtitles: [EngineExternalSubtitle] = [],
         scopedFolder: URL? = nil, temporary: Bool = false, externalAccess: IncomingFileAccess? = nil) {
        self.url = url
        self.headers = headers
        self.embyPlaySessionID = embyPlaySessionID
        self.embyItemID = embyItemID
        self.embyMediaSourceID = embyMediaSourceID
        self.embyUserID = embyUserID
        self.duration = duration
        self.resumePosition = resumePosition
        self.externalSubtitles = externalSubtitles
        self.scopedFolder = scopedFolder
        self.temporary = temporary
        self.externalAccess = externalAccess
    }

    func release() {
        externalAccess = nil
        scopedFolder?.stopAccessingSecurityScopedResource()
        if temporary { try? FileManager.default.removeItem(at: url) }
    }
}

enum PlaybackFailure: LocalizedError {
    case missingFile, unavailableAsset
    var errorDescription: String? {
        switch self {
        case .missingFile: VesperLocalization.string("视频文件不存在或无法访问。")
        case .unavailableAsset: VesperLocalization.string("无法读取相册视频，请检查照片权限和网络连接。")
        }
    }
}

@MainActor
struct PlaybackResourceResolver {
    private let playbackServices: any MediaSourcePlaybackService

    init(playbackServices: any MediaSourcePlaybackService = MediaSourceServices.playback) {
        self.playbackServices = playbackServices
    }

    func resolve(_ item: MediaItem, source: MediaSource, position: Double = 0) async throws -> ResolvedPlaybackResource {
        guard item.id.sourceID == source.id else { throw PlaybackFailure.missingFile }
        switch source.kind {
        case .local:
            let folder = try source.localFolderURL()
            let scoped = folder.startAccessingSecurityScopedResource()
            let base = folder.resolvingSymlinksInPath().standardizedFileURL
            let file = base.appendingPathComponent(item.id.localID).standardizedFileURL
            guard !item.id.localID.hasPrefix("/"),
                  !item.id.localID.split(separator: "/").contains(".."),
                  file.resolvingSymlinksInPath().standardizedFileURL == file,
                  file.pathComponents.starts(with: base.pathComponents),
                  file != base,
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
        case .emby:
            let playback = try await playbackServices.playbackResource(
                item: item, source: source, position: position
            )
            return ResolvedPlaybackResource(url: playback.resource.url, headers: playback.resource.headers,
                                            embyPlaySessionID: playback.sessionID, embyItemID: item.embyItemID,
                                            embyMediaSourceID: playback.mediaSourceID,
                                            embyUserID: source.emby?.userID, duration: playback.duration,
                                            resumePosition: playback.resumePosition,
                                            externalSubtitles: playback.subtitles)
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
