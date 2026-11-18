import SwiftUI
import UIKit
import AVFoundation
@preconcurrency import Photos

/// Shared by the Photos grid and local folder browser.
struct MediaThumbnail: View {
    let source: MediaSource
    let item: MediaItem
    var playback: PlaybackSession? = nil
    var historyEntry: PlaybackHistoryEntry? = nil
    var aspectRatio: CGFloat = 2.0 / 3.0
    var logsQueueDiagnostics = false
    var cacheOnly = false
    var cornerRadius: CGFloat = 12
    var fixedHeight: CGFloat? = nil
    var preloadedData: Data? = nil
    var artworkIsPrepared = false
    var showsPlaceholder = true
    @State private var image: UIImage?

    var body: some View {
        sizedArtwork
        .overlay(alignment: .bottomLeading) {
            if let historyEntry {
                ThumbnailProgressBadge(position: historyEntry.position, total: historyEntry.duration, showsPosition: true, title: mediaDisplayName(item.title))
            } else if let playback {
                ThumbnailPlaybackProgress(session: playback, source: source, item: item)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .contentShape(Rectangle())
        .accessibilityHidden(true)
        .task(id: "\(AppCacheStore.embyArtworkKey(for: item, source: source)):\(aspectRatio)") {
            guard !artworkIsPrepared else { return }
            image = nil
            if logsQueueDiagnostics { PlayerQueueDiagnostic.write("thumbnail.begin source=\(source.kind.rawValue) item=\(item.id.localID)") }
            let data = await MediaThumbnailLoader.shared.load(item, source: source, aspectRatio: aspectRatio,
                                                             diagnostics: logsQueueDiagnostics, cacheOnly: cacheOnly)
            guard !Task.isCancelled else {
                if logsQueueDiagnostics { PlayerQueueDiagnostic.write("thumbnail.cancelled item=\(item.id.localID)") }
                return
            }
            if let data, let loadedImage = UIImage(data: data) {
                image = loadedImage
            }
            if logsQueueDiagnostics { PlayerQueueDiagnostic.write("thumbnail.end item=\(item.id.localID) bytes=\(data?.count ?? 0) decoded=\(image != nil)") }
        }
    }

    @ViewBuilder
    private var sizedArtwork: some View {
        if let fixedHeight {
            artwork.frame(height: fixedHeight)
        } else {
            artwork.aspectRatio(aspectRatio, contentMode: .fit)
        }
    }

    private var artwork: some View {
        GeometryReader { geometry in
            ZStack {
                if showsPlaceholder { Rectangle().fill(.regularMaterial) }
                if let cover = artworkIsPrepared ? preloadedData.flatMap({ UIImage(data: $0) }) : image {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
        }
    }
}

struct EmbyFeaturedArtwork: Sendable {
    var poster: Data?
    var logo: Data?
}

@MainActor
final class MediaThumbnailLoader {
    static let shared = MediaThumbnailLoader()
    private let durationCache = NSCache<NSString, NSNumber>()
    private var pendingEmbyImages: [String: Task<Data?, Never>] = [:]

    private init() {
        durationCache.countLimit = 256
    }

    func prepareFeaturedArtwork(_ items: [MediaItem], source: MediaSource) async -> [MediaID: EmbyFeaturedArtwork] {
        await withTaskGroup(of: (MediaID, EmbyFeaturedArtwork).self) { group in
            for item in items {
                group.addTask { (item.id, await self.featuredArtwork(for: item, source: source)) }
            }
            var artwork: [MediaID: EmbyFeaturedArtwork] = [:]
            for await (id, images) in group { artwork[id] = images }
            return artwork
        }
    }

    func featuredArtwork(for item: MediaItem, source: MediaSource) async -> EmbyFeaturedArtwork {
        guard item.id.sourceID == source.id else { return .init() }
        async let logo = featuredLogo(for: item, source: source)
        async let poster = textlessPoster(for: item, source: source)
        return await EmbyFeaturedArtwork(poster: poster, logo: logo)
    }

    private func featuredLogo(for item: MediaItem, source: MediaSource) async -> Data? {
        guard let url = item.embyPresentation?.logoURL else { return nil }
        let key = "featured-logo|\(AppCacheStore.scope(for: source))|\(url.absoluteString)"
        let (cached, generation) = await AppCacheStore.shared.image(key: key)
        if let cached, UIImage(data: cached) != nil { return cached }
        guard let data = await EmbyRepository.shared.featuredLogoData(for: url, source: source),
              UIImage(data: data) != nil, !Task.isCancelled else { return nil }
        await AppCacheStore.shared.saveImage(data, key: key, generation: generation)
        return data
    }

    private func textlessPoster(for item: MediaItem, source: MediaSource) async -> Data? {
        let key = "featured-textless|\(AppCacheStore.embyArtworkKey(for: item, source: source))"
        let (cached, generation) = await AppCacheStore.shared.image(key: key)
        if let cached, UIImage(data: cached) != nil { return cached }
        for url in await EmbyRepository.shared.featuredPosterCandidates(for: item, source: source) {
            guard !Task.isCancelled else { return nil }
            // Provider artwork uses an unauthenticated request.
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.httpShouldHandleCookies = false
            guard let (data, response) = try? await EmbyNetworkSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 8 * 1024 * 1024, UIImage(data: data) != nil else { continue }
            guard !Task.isCancelled else { return nil }
            await AppCacheStore.shared.saveImage(data, key: key, generation: generation)
            return data
        }
        return nil
    }

    func load(_ item: MediaItem, source: MediaSource, aspectRatio: CGFloat = 2.0 / 3.0,
              diagnostics: Bool = false, cacheOnly: Bool = false) async -> Data? {
        guard item.id.sourceID == source.id, !Task.isCancelled else { return nil }
        switch source.kind {
        case .demo: return nil
        case .emby:
            let key = AppCacheStore.embyArtworkKey(for: item, source: source)
            let (data, generation) = await AppCacheStore.shared.image(key: key)
            if let data, UIImage(data: data) != nil { return data }
            let requestKey = "\(key)|\(generation)"
            if let pending = pendingEmbyImages[requestKey] { return await pending.value }
            guard !cacheOnly, !Task.isCancelled else { return nil }
            let task = Task { () -> Data? in
                defer { pendingEmbyImages[requestKey] = nil }
                guard let data = await EmbyRepository.shared.thumbnailData(for: item, source: source),
                      UIImage(data: data) != nil else { return nil }
                await AppCacheStore.shared.saveImage(data, key: key, generation: generation)
                return data
            }
            pendingEmbyImages[requestKey] = task
            return await task.value
        case .photos:
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id.localID], options: nil).firstObject else { return nil }
            let key = "photos:\(item.id.localID):\(asset.modificationDate?.timeIntervalSince1970 ?? 0):\(aspectRatio)"
            return await cachedImage(key: key, cacheOnly: cacheOnly) {
                let targetSize = CGSize(width: 400, height: 400 / max(0.1, aspectRatio))
                return await PhotoThumbnailRequest().load(asset, targetSize: targetSize, diagnostics: diagnostics)
            }
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
            let key = "local:\(source.id):\(item.id.localID):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)"
            return await cachedImage(key: key, cacheOnly: cacheOnly) {
                await VideoImporter.shared.thumbnail(at: url)
            }
        }
    }

    func duration(_ item: MediaItem, source: MediaSource) async -> Double {
        guard item.id.sourceID == source.id, !Task.isCancelled else { return 0 }
        switch source.kind {
        case .emby: return item.duration ?? 0
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

    private func cachedImage(key: String, cacheOnly: Bool, generate: () async -> Data?) async -> Data? {
        let (data, generation) = await AppCacheStore.shared.image(key: key)
        if let data, UIImage(data: data) != nil { return data }
        guard !cacheOnly, !Task.isCancelled,
              let data = await generate(), UIImage(data: data) != nil, !Task.isCancelled else { return nil }
        await AppCacheStore.shared.saveImage(data, key: key, generation: generation)
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
    private var progress: Double {
        guard remembersProgress else { return 0 }
        return source.kind == .emby ? (item.resumePosition ?? 0) : session.savedProgress(for: item)
    }
    private var total: Double { duration > 0 ? duration : session.savedDuration(for: item) }
    var body: some View {
        Group {
            if progress > 0 && total > 0 {
                ThumbnailProgressBadge(position: progress, total: total)
            }
        }
        .task(id: progress > 0 ? item.id : nil) {
            guard progress > 0 else { return }
            let result = await MediaThumbnailLoader.shared.duration(item, source: source)
            guard !Task.isCancelled else { return }
            duration = result
        }
    }
}

private struct ThumbnailProgressBadge: View {
    let position: Double
    let total: Double
    var showsPosition = false
    var title: String? = nil
    @ScaledMetric(relativeTo: .caption2) private var progressWidth = 20.0
    private var fraction: CGFloat {
        guard total.isFinite, position.isFinite, total > 0 else { return 0 }
        return CGFloat(min(1, max(0, position / total)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title { Text(verbatim: title).font(.caption).lineLimit(1).truncationMode(.tail) }
            HStack(spacing: 5) {
                if total > 0 {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.35))
                            Capsule().fill(.white)
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: geometry.size.width * fraction)
                                }
                        }
                    }
                    .frame(width: progressWidth, height: 4)
                }
                Text(verbatim: showsPosition && total > 0 ? "\(mediaTimeLabel(position)) / \(mediaTimeLabel(total))" : mediaTimeLabel(total))
                    .font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.bottom, 8)
        .frame(maxWidth: .infinity, minHeight: title == nil ? 44 : 64, alignment: .bottomLeading)
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                }
                .mask {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                }
                .environment(\.colorScheme, .dark)
        }
    }
}

/// Ignore degraded previews and resume exactly once, including cancellation.
@MainActor
private final class PhotoThumbnailRequest {
    private var continuation: CheckedContinuation<Data?, Never>?
    private var requestID: PHImageRequestID?

    func load(_ asset: PHAsset, targetSize: CGSize, diagnostics: Bool) async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                self.continuation = continuation
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true
                requestID = PHImageManager.default().requestImage(for: asset,
                    targetSize: targetSize, contentMode: .aspectFill,
                    options: options) { @Sendable [weak self] image, info in
                        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                        let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                        let error = (info?[PHImageErrorKey] as? NSError)?.code
                        let hasImage = image != nil
                        if diagnostics {
                            Task { @MainActor in PlayerQueueDiagnostic.write("photos.thumbnail.callback degraded=\(degraded) cancelled=\(cancelled) error=\(error.map(String.init) ?? "none") image=\(hasImage)") }
                        }
                        guard !degraded else { return }
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

func mediaTimeLabel(_ time: Double) -> String {
    let value = time.isFinite ? Int(max(0, time)) : 0
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        : String(format: "%d:%02d", value / 60, value % 60)
}

/// Native context previews supply the lift/return animation and dimmed, blurred
/// background, while keeping the menu's source rectangle on the thumbnail only.
struct MediaThumbnailMenu<Actions: View>: ViewModifier {
    let source: MediaSource
    let item: MediaItem
    @ObservedObject var playback: PlaybackSession
    var historyEntry: PlaybackHistoryEntry? = nil
    var preloadedData: Data? = nil
    var artworkIsPrepared = false
    var showsEmbyFacts = false
    @ViewBuilder let actions: () -> Actions
    @State private var shareResource: ResolvedPlaybackResource?
    @State private var showingShare = false
    @State private var preparingShare = false
    @State private var shareError: String?
    @State private var showingShareError = false
    @State private var showingEmbyDetails = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if source.kind == .emby {
                    Button("详情", systemImage: "info.circle") { showingEmbyDetails = true }
                } else {
                    Button("分享", systemImage: "square.and.arrow.up") { share() }
                        .disabled(preparingShare)
                }
                if playback.savedProgress(for: item) > 0 || playback.history.contains(where: { $0.mediaID == item.id }) {
                    Button(source.kind == .emby ? "清除本地记录" : "清除播放进度", systemImage: "clock.arrow.circlepath") {
                        playback.clearSavedProgress(for: item)
                    }
                }
                actions()
            } preview: {
                MediaThumbnailPreview(source: source, item: item, historyEntry: historyEntry,
                                      preloadedData: preloadedData, artworkIsPrepared: artworkIsPrepared,
                                      showsEmbyFacts: showsEmbyFacts)
            }
            .sheet(isPresented: $showingShare, onDismiss: {
                shareResource?.release()
                shareResource = nil
            }) {
                if let shareResource { MediaVideoShareSheet(url: shareResource.url) }
            }
            .sheet(isPresented: $showingEmbyDetails) {
                NavigationStack { embySheetDetails(source: source, item: item) }
            }
            .alert("无法分享视频", isPresented: $showingShareError) {
                Button("好", role: .cancel) { }
            } message: { Text(verbatim: shareError ?? "") }
    }

    private func share() {
        guard !preparingShare else { return }
        preparingShare = true
        Task { @MainActor in
            defer { preparingShare = false }
            do {
                let resource = try await PlaybackResourceResolver().resolve(item, source: source)
                guard !Task.isCancelled else { resource.release(); return }
                shareResource = resource
                showingShare = true
            } catch {
                shareError = error.localizedDescription
                showingShareError = true
            }
        }
    }
}

private struct MediaThumbnailPreview: View {
    let source: MediaSource
    let item: MediaItem
    var historyEntry: PlaybackHistoryEntry? = nil
    var preloadedData: Data? = nil
    var artworkIsPrepared = false
    var showsEmbyFacts = false
    @State private var duration: Double = 0
    private var displayName: String {
        VideoImporter.isVideoType(URL(fileURLWithPath: item.title)) ? (item.title as NSString).deletingPathExtension : item.title
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MediaThumbnail(source: source, item: item, cacheOnly: true,
                           preloadedData: preloadedData, artworkIsPrepared: artworkIsPrepared)
                .frame(width: 200, height: 300)
            Text(verbatim: displayName).lineLimit(2)
            if let historyEntry {
                Text(verbatim: "\(mediaTimeLabel(historyEntry.position)) / \(mediaTimeLabel(historyEntry.duration))")
                    .foregroundStyle(.secondary)
                Text(historyEntry.watchedAt, format: .dateTime.hour().minute())
                    .foregroundStyle(.secondary)
            } else if showsEmbyFacts {
                EmbyPreviewFacts(item: item)
            } else if duration > 0 {
                Text(verbatim: mediaTimeLabel(duration)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 228)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .task {
            if !showsEmbyFacts { duration = await MediaThumbnailLoader.shared.duration(item, source: source) }
        }
    }
}

private struct MediaVideoShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

func mediaDisplayName(_ title: String) -> String {
    VideoImporter.isVideoType(URL(fileURLWithPath: title)) ? (title as NSString).deletingPathExtension : title
}

@MainActor
enum PlayerQueueDiagnostic {
    static func write(_ message: String) {
        AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [PlayerQueue] \(message)")
    }
}
