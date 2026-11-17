import SwiftUI
import AVFoundation
@preconcurrency import Photos

/// Shared by the Photos grid and local folder browser.
struct MediaThumbnail: View {
    let source: MediaSource
    let item: MediaItem
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color("VesperSecondaryBackground")
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    Image(systemName: "play.rectangle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
        .task(id: item.id) {
            image = nil
            let data = await MediaThumbnailLoader.shared.load(item, source: source)
            guard !Task.isCancelled else { return }
            image = data.flatMap { UIImage(data: $0) }
        }
    }
}

@MainActor
private final class MediaThumbnailLoader {
    static let shared = MediaThumbnailLoader()
    private let cache = NSCache<NSString, NSData>()

    private init() {
        cache.countLimit = 160
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func load(_ item: MediaItem, source: MediaSource) async -> Data? {
        guard item.id.sourceID == source.id, !Task.isCancelled else { return nil }
        switch source.kind {
        case .demo: return nil
        case .photos:
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id.localID], options: nil).firstObject else { return nil }
            let key = "photos:\(item.id.localID):\(asset.modificationDate?.timeIntervalSince1970 ?? 0)" as NSString
            if let data = cache.object(forKey: key) { return data as Data }
            let data = await PhotoThumbnailRequest().load(asset)
            return remember(data, key: key)
        case .local:
            guard let root = try? source.localFolderURL() else { return nil }
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let base = root.resolvingSymlinksInPath().standardizedFileURL
            let url = base.appendingPathComponent(item.id.localID).standardizedFileURL
            guard !item.id.localID.hasPrefix("/"),
                  !item.id.localID.split(separator: "/").contains(".."),
                  url.resolvingSymlinksInPath().standardizedFileURL == url,
                  url.pathComponents.starts(with: base.pathComponents), url != base,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true else { return nil }
            let key = "local:\(source.id):\(item.id.localID):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)" as NSString
            if let data = cache.object(forKey: key) { return data as Data }
            let data = await VideoImporter.shared.thumbnail(at: url)
            return remember(data, key: key)
        }
    }

    private func remember(_ data: Data?, key: NSString) -> Data? {
        guard !Task.isCancelled, let data else { return nil }
        cache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }
}

/// Ignore degraded previews and resume exactly once, including cancellation.
@MainActor
private final class PhotoThumbnailRequest {
    private var continuation: CheckedContinuation<Data?, Never>?
    private var requestID: PHImageRequestID?

    func load(_ asset: PHAsset) async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                self.continuation = continuation
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true
                requestID = PHImageManager.default().requestImage(for: asset,
                    targetSize: CGSize(width: 600, height: 400), contentMode: .aspectFill,
                    options: options) { image, info in
                        guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                        let data = image?.jpegData(compressionQuality: 0.8)
                        Task { @MainActor [weak self] in self?.finish(data) }
                    }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func finish(_ data: Data?) {
        let pending = continuation
        continuation = nil
        requestID = nil
        pending?.resume(returning: data)
    }

    private func cancel() {
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        finish(nil)
    }
}
