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
    var imageOrientation: EmbyImageOrientation = .portrait
    var crossfadesArtwork = false
    var allowsRemotePrimary = true
    var logsQueueDiagnostics = false
    var cacheOnly = false
    var cornerRadius: CGFloat = 12
    var fixedHeight: CGFloat? = nil
    var preloadedData: Data? = nil
    var missingArtworkSymbol: String? = nil
    var artworkIsPrepared = false
    var mirroredEdgeFraction: CGFloat = 0
    var showsMissingArtwork = true
    var usesMediaCardBackdrop = true
    var prefersLandscapeMovieArtwork = false
    var bottomArtworkBlur: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadedArtwork: LoadedArtwork?

    private struct LoadedArtwork {
        let key: String
        let image: UIImage?
    }

    private var loadKey: String {
        "\(AppCacheStore.embyArtworkKey(for: item, source: source)):\(aspectRatio):\(imageOrientation.rawValue):\(cacheOnly):\(prefersLandscapeMovieArtwork && item.embyItemType == "Movie"):\(ImageCacheDebugSettings.ignoresLocalCache)"
    }

    var body: some View {
        sizedArtwork
        .overlay(alignment: .bottomLeading) {
            if let historyEntry {
                MediaPlaybackStatus(position: historyEntry.position, duration: historyEntry.duration,
                                    played: historyEntry.isFullyWatched)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .bottomLeading)
                    .background {
                        Rectangle().fill(.regularMaterial)
                            .mask {
                                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            }
                    }
            } else if let playback {
                ThumbnailPlaybackProgress(session: playback, source: source, item: item)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            if mirroredEdgeFraction > 0 {
                mirroredEdges
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityHidden(true)
        .task(id: artworkIsPrepared ? nil : loadKey) {
            guard !artworkIsPrepared else { return }
            let key = loadKey
            if logsQueueDiagnostics { PlayerQueueDiagnostic.write("thumbnail.begin source=\(source.kind.rawValue) item=\(item.id.localID)") }
            let data = await MediaThumbnailLoader.shared.load(item, source: source, service: MediaSourceServices.artwork, aspectRatio: aspectRatio,
                                                             imageOrientation: imageOrientation, allowsRemotePrimary: allowsRemotePrimary,
                                                             diagnostics: logsQueueDiagnostics, cacheOnly: cacheOnly,
                                                             prefersLandscapeMovieArtwork: prefersLandscapeMovieArtwork)
            guard !Task.isCancelled else {
                if logsQueueDiagnostics { PlayerQueueDiagnostic.write("thumbnail.cancelled item=\(item.id.localID)") }
                return
            }
            let image = data.flatMap { UIImage(data: $0) }
            loadedArtwork = LoadedArtwork(key: key, image: image)
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

    private var cover: UIImage? {
        if artworkIsPrepared { return preloadedData.flatMap { UIImage(data: $0) } }
        return loadedArtwork?.key == loadKey ? loadedArtwork?.image : nil
    }

    private var artworkIdentity: Int? {
        if artworkIsPrepared { return preloadedData?.hashValue }
        return loadedArtwork?.key == loadKey ? loadedArtwork?.image.map { ObjectIdentifier($0).hashValue } : nil
    }

    private var artwork: some View {
        GeometryReader { geometry in
            let cover = cover
            let finishedLoading = artworkIsPrepared || loadedArtwork?.key == loadKey
            ZStack {
                if usesMediaCardBackdrop {
                    MediaCardBackdrop(showsMissingArtwork: showsMissingArtwork && finishedLoading && cover == nil,
                                      missingArtworkSymbol: missingArtworkSymbol)
                } else {
                    Rectangle().fill(.regularMaterial)
                }
                ZStack {
                    if let cover {
                        croppedArtwork(cover, size: geometry.size)
                            .overlay(alignment: .bottom) {
                                if bottomArtworkBlur > 0 {
                                    croppedArtwork(cover, size: geometry.size)
                                        .padding(bottomArtworkBlur * 2)
                                        .blur(radius: bottomArtworkBlur)
                                        .frame(width: geometry.size.width, height: geometry.size.height / 4,
                                               alignment: .bottom)
                                        .offset(y: bottomArtworkBlur * 2)
                                        .frame(height: geometry.size.height / 4)
                                        .mask {
                                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                        }
                                        .allowsHitTesting(false)
                                }
                            }
                            .id(crossfadesArtwork ? artworkIdentity : nil)
                            .transition(.opacity)
                    }
                }
                .animation(crossfadesArtwork && !reduceMotion ? .easeInOut(duration: 0.3) : nil,
                           value: crossfadesArtwork ? artworkIdentity : nil)
            }
        }
    }

    private func croppedArtwork(_ image: UIImage, size: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    private var mirroredEdges: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let edgeWidth = size.width * mirroredEdgeFraction
            let reflection = ZStack {
                MediaCardBackdrop()
                if let cover { croppedArtwork(cover, size: size).scaleEffect(x: -1, y: 1) }
            }
            .frame(width: size.width, height: size.height)

            // Reflect the visible crop so the outermost pixels meet along each edge.
            reflection
                .frame(width: edgeWidth, alignment: .trailing)
                .clipped()
                .offset(x: -edgeWidth)
            reflection
                .frame(width: edgeWidth, alignment: .leading)
                .clipped()
                .offset(x: size.width)
        }
    }
}

struct EmbyFeaturedArtwork: Sendable {
    var poster: Data?
    var logo: Data?
}

private struct CarouselArtworkPartResult: Sendable {
    enum Part: Sendable {
        case poster
        case logo
    }

    let id: MediaID
    let part: Part
    let data: Data?
}

@MainActor
final class MediaThumbnailLoader {
    static let shared = MediaThumbnailLoader()
    private let durationCache = NSCache<NSString, NSNumber>()
    private var pendingEmbyImages: [String: Task<Data?, Never>] = [:]

    private init() {
        durationCache.countLimit = 256
    }

    func prepareCarouselArtwork(
        _ items: [MediaItem],
        source: MediaSource,
        service: any MediaSourceArtworkService = MediaSourceServices.artwork,
        onArtworkReady: (@MainActor (MediaID, EmbyFeaturedArtwork) -> Void)? = nil
    ) async -> [MediaID: EmbyFeaturedArtwork] {
        await withTaskGroup(of: CarouselArtworkPartResult.self) { group in
            for item in items {
                group.addTask {
                    CarouselArtworkPartResult(
                        id: item.id,
                        part: .logo,
                        data: await self.featuredLogo(for: item, source: source, service: service)
                    )
                }
                group.addTask {
                    var poster = await self.textlessPoster(for: item, source: source, service: service)
                    if poster == nil, !Task.isCancelled {
                        poster = await self.load(item, source: source, aspectRatio: 3.0 / 5.0,
                                                 imageOrientation: .portrait)
                    }
                    return CarouselArtworkPartResult(id: item.id, part: .poster, data: poster)
                }
            }
            var result: [MediaID: EmbyFeaturedArtwork] = [:]
            var logos: [MediaID: Data] = [:]
            for await update in group {
                switch update.part {
                case .poster:
                    guard let poster = update.data else { continue }
                    let artwork = EmbyFeaturedArtwork(poster: poster, logo: logos[update.id])
                    result[update.id] = artwork
                    onArtworkReady?(update.id, artwork)
                case .logo:
                    guard let logo = update.data else { continue }
                    logos[update.id] = logo
                    guard var artwork = result[update.id] else { continue }
                    artwork.logo = logo
                    result[update.id] = artwork
                    onArtworkReady?(update.id, artwork)
                }
            }
            return result
        }
    }

    func featuredArtwork(for item: MediaItem, source: MediaSource, service: any MediaSourceArtworkService = MediaSourceServices.artwork) async -> EmbyFeaturedArtwork {
        guard item.id.sourceID == source.id else { return .init() }
        async let logo = featuredLogo(for: item, source: source, service: service)
        async let poster = textlessPoster(for: item, source: source, service: service)
        return await EmbyFeaturedArtwork(poster: poster, logo: logo)
    }

    private func featuredLogo(for item: MediaItem, source: MediaSource, service: any MediaSourceArtworkService) async -> Data? {
        let key = "featured-logo|\(AppCacheStore.scope(for: source))|\(item.id.localID)"
        let ignoresCache = ImageCacheDebugSettings.ignoresLocalCache
        let (cached, generation) = await AppCacheStore.shared.image(key: key, ignoringLocalCache: ignoresCache)
        if let cached, UIImage(data: cached) != nil { return cached }
        guard let data = await service.artworkData(for: item, source: source, purpose: .logo, orientation: .landscape, allowsRemotePrimary: false, prefersLandscapeMovieArtwork: false),
              UIImage(data: data) != nil, !Task.isCancelled else { return nil }
        if !ignoresCache {
            await AppCacheStore.shared.saveImage(data, key: key, generation: generation)
        }
        return data
    }

    private func textlessPoster(for item: MediaItem, source: MediaSource, service: any MediaSourceArtworkService) async -> Data? {
        let key = "featured-textless|\(AppCacheStore.embyArtworkKey(for: item, source: source))"
        let ignoresCache = ImageCacheDebugSettings.ignoresLocalCache
        let (cached, generation) = await AppCacheStore.shared.image(key: key, ignoringLocalCache: ignoresCache)
        if let cached, UIImage(data: cached) != nil { return cached }
        for url in await service.featuredPosterCandidates(for: item, source: source) {
            guard !Task.isCancelled else { return nil }
            // Provider artwork uses an unauthenticated request.
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.httpShouldHandleCookies = false
            guard let (data, response) = try? await EmbyNetworkSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 8 * 1024 * 1024, UIImage(data: data) != nil else { continue }
            guard !Task.isCancelled else { return nil }
            if !ignoresCache {
                await AppCacheStore.shared.saveImage(data, key: key, generation: generation)
            }
            return data
        }
        return nil
    }

    func load(_ item: MediaItem, source: MediaSource, service: any MediaSourceArtworkService = MediaSourceServices.artwork, aspectRatio: CGFloat = 2.0 / 3.0,
              imageOrientation: EmbyImageOrientation = .portrait,
              allowsRemotePrimary: Bool = true, diagnostics: Bool = false, cacheOnly: Bool = false,
              prefersLandscapeMovieArtwork: Bool = false) async -> Data? {
        guard item.id.sourceID == source.id, !Task.isCancelled else { return nil }
        switch source.kind {
        case .demo: return nil
        case .emby:
            let prefersLandscape = prefersLandscapeMovieArtwork && item.embyItemType == "Movie"
            let variant = prefersLandscape ? "|movie-landscape" : ""
            let key = "\(AppCacheStore.embyArtworkKey(for: item, source: source))|\(imageOrientation.rawValue)\(variant)"
            let ignoresCache = ImageCacheDebugSettings.ignoresLocalCache
            let (data, generation) = await AppCacheStore.shared.image(key: key, ignoringLocalCache: ignoresCache)
            if let data, UIImage(data: data) != nil { return data }
            let requestKey = "\(key)|\(generation)|\(ignoresCache)|remote:\(allowsRemotePrimary)"
            if let pending = pendingEmbyImages[requestKey] { return await pending.value }
            guard !cacheOnly, !Task.isCancelled else { return nil }
            let task = Task { () -> Data? in
                defer { pendingEmbyImages[requestKey] = nil }
                guard let data = await service.artworkData(for: item, source: source,
                            purpose: item.embyItemType == "Person" ? .avatar : imageOrientation == .landscape ? .thumbnail : .poster,
                            orientation: imageOrientation, allowsRemotePrimary: allowsRemotePrimary,
                            prefersLandscapeMovieArtwork: prefersLandscape),
                      UIImage(data: data) != nil else { return nil }
                if !ignoresCache {
                    await AppCacheStore.shared.saveImage(data, key: key, generation: generation)
                }
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
        let ignoresCache = ImageCacheDebugSettings.ignoresLocalCache
        let (data, generation) = await AppCacheStore.shared.image(key: key, ignoringLocalCache: ignoresCache)
        if let data, UIImage(data: data) != nil { return data }
        guard !cacheOnly, !Task.isCancelled,
              let data = await generate(), UIImage(data: data) != nil, !Task.isCancelled else { return nil }
        if !ignoresCache {
            await AppCacheStore.shared.saveImage(data, key: key, generation: generation)
        }
        return data
    }
}


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
    var artworkItem: MediaItem? = nil
    var previewTitle: String? = nil
    var preloadedData: Data? = nil
    var artworkIsPrepared = false
    var showsEmbyFacts = false
    var openEmbyDetails: (() -> Void)? = nil
    @ViewBuilder let actions: () -> Actions
    @State private var shareResource: ResolvedPlaybackResource?
    @State private var showingShare = false
    @State private var preparingShare = false
    @State private var shareError: String?
    @State private var showingShareError = false
    @State private var showingEmbyDetails = false
    @Namespace private var detailsZoom
    @State private var updatingWatchState = false
    @State private var clearedServerProgress = false
    @State private var watchError: String?
    @State private var favoriteError: String?

    private var showsWatchActions: Bool {
        source.kind == .emby && showsEmbyFacts && !item.isContainer
    }

    private var hasPlaybackProgress: Bool {
        !clearedServerProgress && playback.resumePosition(for: item) > 0
    }

    private var canClearTraktProgress: Bool {
        source.kind == .emby && TraktAccountStore.shared.isConnected
            && ["Movie", "Episode", "Video", "MusicVideo"].contains(item.embyItemType ?? "")
    }

    @ViewBuilder
    private func detailsArtwork(_ content: Content) -> some View {
        if source.kind == .emby, item.isEmbySeries, openEmbyDetails == nil {
            content.matchedTransitionSource(id: item.id, in: detailsZoom)
        } else {
            content
        }
    }

    func body(content: Content) -> some View {
        detailsArtwork(content)
            .contextMenu {
                if source.kind == .emby {
                    Button("详情", systemImage: "info.circle") {
                        if let openEmbyDetails { openEmbyDetails() }
                        else { showingEmbyDetails = true }
                    }
                } else {
                    Button("分享", systemImage: "square.and.arrow.up") { share() }
                        .disabled(preparingShare)
                }
                if source.kind == .emby, ["Movie", "Series"].contains(item.embyItemType ?? "") {
                    let favorite = playback.effectiveFavorite(for: item)
                    Button(favorite ? "取消收藏" : "收藏",
                           systemImage: favorite ? "heart.slash" : "heart") {
                        playback.setFavorite(!favorite, for: item, source: source) { favoriteError = $0 }
                    }
                    .disabled(source.emby?.userID == nil)
                }
                if showsWatchActions {
                    if hasPlaybackProgress || canClearTraktProgress {
                        Button("清除播放进度", systemImage: "clock.arrow.circlepath") { clearProgress() }
                            .disabled(updatingWatchState || (hasPlaybackProgress && source.emby?.userID == nil && !canClearTraktProgress))
                    }
                } else if !showsEmbyFacts && (playback.savedProgress(for: item) > 0
                    || playback.history.contains(where: { $0.mediaID == item.id })) {
                    Button(source.kind == .emby ? "清除本地记录" : "清除播放进度", systemImage: "clock.arrow.circlepath") {
                        playback.clearSavedProgress(for: item, removeFromHistory: historyEntry != nil)
                    }
                }
                if showsWatchActions || (source.kind == .emby && historyEntry != nil) {
                    let played = playback.effectivePlayed(for: item)
                    Button(played ? "标记为未观看" : "标记为已观看",
                           systemImage: played ? "circle" : "checkmark.circle") {
                        playback.setPlayed(!played, for: item, source: source) { watchError = $0 }
                    }
                    .disabled(!playback.canSetPlayed(for: source))
                }
                actions()
            } preview: {
                MediaThumbnailPreview(source: source, item: item, historyEntry: historyEntry,
                                      artworkItem: artworkItem, previewTitle: previewTitle,
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
                embyDetailsSheet(source: source, item: item, artworkZoom: detailsZoom)
            }
            .onChange(of: item.resumePosition) { _, _ in clearedServerProgress = false }
            .alert("无法更新收藏", isPresented: Binding(
                get: { favoriteError != nil }, set: { if !$0 { favoriteError = nil } }
            )) {
                Button("好", role: .cancel) { favoriteError = nil }
            } message: { Text(verbatim: favoriteError ?? "") }
            .alert("无法更新观看记录", isPresented: Binding(
                get: { watchError != nil }, set: { if !$0 { watchError = nil } }
            )) {
                Button("好", role: .cancel) { watchError = nil }
            } message: { Text(verbatim: watchError ?? "") }
            .alert("无法分享视频", isPresented: $showingShareError) {
                Button("好", role: .cancel) { }
            } message: { Text(verbatim: shareError ?? "") }
    }

    private func clearProgress() {
        guard !updatingWatchState else { return }
        updatingWatchState = true
        Task { @MainActor in
            defer { updatingWatchState = false }
            do {
                try await playback.clearProgress(for: item, source: source)
                clearedServerProgress = true
            } catch {
                watchError = error.localizedDescription
            }
        }
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

struct MediaThumbnailPreview: View {
    let source: MediaSource
    let item: MediaItem
    var historyEntry: PlaybackHistoryEntry? = nil
    var artworkItem: MediaItem? = nil
    var previewTitle: String? = nil
    var preloadedData: Data? = nil
    var artworkIsPrepared = false
    var showsEmbyFacts = false
    var usesLandscapeArtwork = false
    @AppStorage("language.code") private var languageCode = "system"
    @State private var duration: Double = 0
    private var displayName: String {
        previewTitle ?? (VideoImporter.isVideoType(URL(fileURLWithPath: item.title)) ? (item.title as NSString).deletingPathExtension : item.title)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let aspectRatio: CGFloat = usesLandscapeArtwork ? 1.5 : 2.0 / 3.0
            MediaThumbnail(source: source, item: artworkItem ?? item, aspectRatio: aspectRatio,
                           imageOrientation: usesLandscapeArtwork ? .landscape : .portrait,
                           allowsRemotePrimary: !usesLandscapeArtwork, cacheOnly: true,
                           preloadedData: preloadedData, artworkIsPrepared: artworkIsPrepared,
                           usesMediaCardBackdrop: historyEntry == nil || usesLandscapeArtwork,
                           prefersLandscapeMovieArtwork: usesLandscapeArtwork)
                .frame(width: 200, height: 200 / aspectRatio)
                .mediaArtworkBorder()
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: displayName).lineLimit(previewTitle == nil ? 2 : nil)
                if let historyEntry {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(historyEntry.watchedAt, format: .dateTime.hour().minute()
                            .locale(VesperLocalization.locale(for: languageCode)))
                        if historyEntry.duration.isFinite && historyEntry.duration > 0 {
                            let minutes = (historyEntry.duration / 60).rounded()
                            Text(verbatim: Measurement(value: max(1, minutes), unit: UnitDuration.minutes)
                                .formatted(.measurement(width: .wide, usage: .asProvided,
                                                        numberFormatStyle: .number.precision(.fractionLength(0)))
                                    .locale(VesperLocalization.locale(for: languageCode))))
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else if showsEmbyFacts {
                    EmbyPreviewFacts(item: item)
                } else if duration > 0 {
                    Text(verbatim: mediaTimeLabel(duration))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 228)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .task {
            if historyEntry == nil && !showsEmbyFacts {
                duration = await MediaThumbnailLoader.shared.duration(item, source: source)
            }
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
