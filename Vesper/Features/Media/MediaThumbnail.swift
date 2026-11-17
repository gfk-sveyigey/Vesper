import SwiftUI
import AVFoundation
@preconcurrency import Photos

/// Shared by the Photos grid and local folder browser.
struct MediaThumbnail: View {
    let source: MediaSource
    let item: MediaItem
    var playback: PlaybackSession? = nil
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
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .overlay(alignment: .bottomLeading) {
            if let playback {
                ThumbnailPlaybackProgress(session: playback, source: source, item: item)
            }
        }
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
    private let durationCache = NSCache<NSString, NSNumber>()

    private init() {
        durationCache.countLimit = 256
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

    func duration(_ item: MediaItem, source: MediaSource) async -> Double {
        guard item.id.sourceID == source.id, !Task.isCancelled else { return 0 }
        switch source.kind {
        case .photos:
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else { return 0 }
            return PHAsset.fetchAssets(withLocalIdentifiers: [item.id.localID], options: nil).firstObject?.duration ?? 0
        case .local:
            guard let resource = try? await PlaybackResourceResolver().resolve(item, source: source) else { return 0 }
            defer { resource.release() }
            let values = try? resource.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let key = "\(source.id):\(item.id.localID):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)" as NSString
            if let cached = durationCache.object(forKey: key) { return cached.doubleValue }
            let asset = AVURLAsset(url: resource.url)
            guard let time = try? await asset.load(.duration), time.seconds.isFinite, time.seconds > 0, !Task.isCancelled else { return 0 }
            durationCache.setObject(NSNumber(value: time.seconds), forKey: key)
            return time.seconds
        case .demo: return 0
        }
    }

    private func remember(_ data: Data?, key: NSString) -> Data? {
        guard !Task.isCancelled, let data else { return nil }
        cache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }
}

/// Only persisted progress is shown, and only while progress retention is enabled.
private struct ThumbnailPlaybackProgress: View {
    @ObservedObject var session: PlaybackSession
    let source: MediaSource
    let item: MediaItem
    @AppStorage("player.rememberProgress") private var remembersProgress = true
    @State private var duration: Double = 0
    private var progress: Double { remembersProgress ? session.savedProgress(for: item) : 0 }
    private var total: Double { duration > 0 ? duration : session.savedDuration(for: item) }
    var body: some View {
        Group {
            if progress > 0 && total > 0 {
                HStack(spacing: 5) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.35))
                            Capsule().fill(.white)
                                .frame(width: geometry.size.width * CGFloat(min(1, max(0, progress / total))))
                        }
                    }
                    .frame(maxWidth: 42).frame(height: 3)
                    Text(verbatim: timeLabel(total)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 6)
                .background(.black.opacity(0.65), in: Capsule())
                .padding(6)
            }
        }
        .task(id: progress > 0 ? item.id : nil) {
            guard progress > 0 else { return }
            let result = await MediaThumbnailLoader.shared.duration(item, source: source)
            guard !Task.isCancelled else { return }
            duration = result
        }
    }
    private func timeLabel(_ seconds: Double) -> String {
        let seconds = Int(max(0, seconds))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
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
                    targetSize: CGSize(width: 400, height: 600), contentMode: .aspectFill,
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
