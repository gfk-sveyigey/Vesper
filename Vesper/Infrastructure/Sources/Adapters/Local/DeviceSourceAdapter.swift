import Foundation
#if canImport(Photos)
import Photos
#endif

struct DeviceSourceAdapter: SourceAdapter {
    func media(in source: MediaSource) async throws -> [MediaItem] {
        if source.kind == .local {
            #if os(iOS)
            let url = try source.localFolderURL()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey])
            return urls.filter { VideoImporter.isVideoType($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
                MediaItem(id: MediaID(sourceID: source.id, localID: $0.lastPathComponent), title: $0.deletingPathExtension().lastPathComponent, resource: nil)
            }
            #else
            throw SourceFailure.unavailable
            #endif
        }
        if source.kind == .photos {
            #if canImport(Photos)
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else { throw SourceFailure.unavailable }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: .video, options: options)
            var items: [MediaItem] = []
            for index in 0..<assets.count {
                try Task.checkCancellation()
                let asset = assets.object(at: index)
                let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? asset.localIdentifier
                let dateAdded: Date?
                if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) {
                    dateAdded = asset.addedDate
                } else {
                    dateAdded = nil
                }
                items.append(MediaItem(id: MediaID(sourceID: source.id, localID: asset.localIdentifier),
                                       title: name, resource: nil, dateAdded: dateAdded))
            }
            return items
            #else
            throw SourceFailure.unavailable
            #endif
        }
        throw SourceFailure.unavailable
    }
}
