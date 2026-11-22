import Foundation
import Combine
import CryptoKit
#if canImport(Photos)
import Photos
#endif

/// Stable identity is scoped to a source, not a title or display URL.
struct MediaID: Hashable, Codable, Sendable {
    let sourceID: UUID
    let localID: String
}

struct PlayableResource: Hashable, Codable, Sendable {
    let url: URL
    var headers: [String: String] = [:]
}

struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    let id: MediaID
    let title: String
    let resource: PlayableResource?
    var subtitle: String? = nil
    var isContainer = false
    var embyItemID: String? = nil
    var embyItemType: String? = nil
    var embyMediaSourceID: String? = nil
    var imageURL: URL? = nil
    var fallbackImageURL: URL? = nil
    var previewImageURL: URL? = nil
    var duration: Double? = nil
    var resumePosition: Double? = nil
    var dateCreated: Date? = nil
    var embyPresentation: EmbyPresentation? = nil

    var isFavorite: Bool? = nil
    var isPlayed: Bool? = nil
    var embyPlayedFetchedAt: Date? = nil

    var isEmbySeries: Bool { embyItemType == "Series" }
}

struct EmbyPresentation: Codable, Hashable, Sendable {
    var genres: [String]
    var premiereDate: Date?
    var status: String?
    var rating: String?
    var logoURL: URL?
    var overview: String? = nil
    var communityRating: Double? = nil
    var studios: [String]? = nil
    var seasonCount: Int? = nil
}

struct SourceCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let browse = Self(rawValue: 1 << 0)
    static let playback = Self(rawValue: 1 << 1)
}

enum DemoSourceBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    case content, empty, failure, offline
    var id: Self { self }
    var titleKey: String {
        switch self {
        case .content: "示例内容"
        case .empty: "空来源"
        case .failure: "连接失败"
        case .offline: "离线"
        }
    }
}

/// Demo is an explicit source kind; service accounts are not media sources.
struct MediaSource: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable { case demo, photos, local, emby }
    let id: UUID
    var name: String
    let kind: Kind
    var folderBookmark: Data? = nil
    var behavior: DemoSourceBehavior
    var emby: EmbySourceConfiguration? = nil
    var capabilities: SourceCapabilities { kind == .demo ? [.browse] : [.browse, .playback] }
}

enum SourceFailure: Error, Equatable {
    case unavailable, offline, message(String)
}

protocol SourceAdapter: Sendable {
    func media(in source: MediaSource) async throws -> [MediaItem]
}

struct DemoSourceAdapter: SourceAdapter {
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
                items.append(MediaItem(id: MediaID(sourceID: source.id, localID: asset.localIdentifier), title: name, resource: nil))
            }
            return items
            #else
            throw SourceFailure.unavailable
            #endif
        }
        if source.kind == .emby {
            return try await EmbyRepository.shared.rootItems(for: source)
        }
        try await Task.sleep(for: .milliseconds(250))
        switch source.behavior {
        case .empty: return []
        case .failure: throw SourceFailure.unavailable
        case .offline: throw SourceFailure.offline
        case .content:
            return (1...6).map { index in
                MediaItem(id: MediaID(sourceID: source.id, localID: String(index)),
                          title: "Demo \(index)", resource: nil)
            }
        }
    }
}

@MainActor
final class SourceLibrary: ObservableObject {
    enum ContentState: Equatable {
        case unselected, loading, loaded([MediaItem]), failed(SourceFailure)
    }
    private struct Snapshot: Codable {
        var sources: [MediaSource]
        var selectedID: UUID?
    }
    @Published private(set) var sources: [MediaSource]

    func moveSources(from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy({ sources.indices.contains($0) }),
              (0...sources.count).contains(destination) else { return }
        let moved = offsets.map { sources[$0] }
        var ordered = sources.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        ordered.insert(contentsOf: moved, at: destination - offsets.filter { $0 < destination }.count)
        sources = ordered
        persist()
    }
    @Published private(set) var selectedID: UUID?
    @Published private(set) var refreshGeneration = 0
    @Published private(set) var content: ContentState = .unselected
    @Published private(set) var storageFailed = false
    enum ConnectionStatus: Equatable { case normal, checking, verified, failed }
    @Published private var connectionStatuses: [UUID: [String: ConnectionStatus]] = [:]
    @Published private(set) var routeLatencies: [UUID: Int] = [:]
    var isTestingRouteLatency: Bool { !connectionChecks.isEmpty }
    private var connectionChecks: [UUID: Task<Void, Never>] = [:]
    private var connectionGenerations: [UUID: UUID] = [:]

    func connectionStatus(for source: MediaSource, address: String? = nil) -> ConnectionStatus {
        guard let configuration = source.emby else { return .normal }
        return connectionStatuses[source.id]?[EmbyRouteOptions.key(address ?? configuration.serverAddress)] ?? .normal
    }

    /// Feedback only: verification never blocks or rolls back the selected route.
    func verifyEmbyConnection(_ id: UUID) {
        guard let source = sources.first(where: { $0.id == id }), let configuration = source.emby else { return }
        connectionChecks[id]?.cancel()
        connectionStatuses[id] = connectionStatuses[id]?.mapValues { $0 == .checking ? .normal : $0 }
        let generation = UUID()
        connectionGenerations[id] = generation
        let key = EmbyRouteOptions.key(configuration.serverAddress)
        connectionStatuses[id, default: [:]][key] = .checking
        routeLatencies[id] = nil
        connectionChecks[id] = Task { [weak self] in
            let result: ConnectionStatus
            do {
                try await EmbyAccountStore.shared.verifyConnection(for: source) { duration in
                    guard let self, !Task.isCancelled, self.connectionGenerations[id] == generation else { return }
                    let components = duration.components
                    self.routeLatencies[id] = max(1, Int(components.seconds * 1_000
                        + components.attoseconds / 1_000_000_000_000_000))
                }
                result = .verified
            } catch {
                result = .failed
            }
            guard let self, !Task.isCancelled, self.connectionGenerations[id] == generation,
                  self.sources.first(where: { $0.id == id })?.emby?.serverAddress == configuration.serverAddress else { return }
            self.connectionChecks[id] = nil
            self.connectionStatuses[id, default: [:]][key] = result
        }
    }

    private let defaults: UserDefaults
    private let adapter: any SourceAdapter
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private static let storageKey = "sources.snapshot.v1"
    private var embyParentStack: [(MediaItem, [MediaItem], Bool)] = []
    private var currentEmbyParentID: String?
    @Published private(set) var hasMoreEmbyItems = false
    @Published private(set) var loadingMore = false
    @Published private(set) var paginationError: String?
    struct EmbyHome {
        let scope: String
        var groups: [EmbyMediaGroup]
        var featured: [MediaItem]
        var artwork: [String: Data]? = nil
        var featuredArtwork: [MediaID: EmbyFeaturedArtwork]? = nil
    }

    @Published private(set) var embyHome: EmbyHome?
    @Published private(set) var isLoadingEmbyHome = false
    private var moreRequest: Task<Void, Never>?

    var canNavigateBack: Bool { !embyParentStack.isEmpty }

    var selectedSource: MediaSource? { sources.first { $0.id == selectedID } }

    init(defaults: UserDefaults = .standard, adapter: any SourceAdapter = DemoSourceAdapter()) {
        self.defaults = defaults
        self.adapter = adapter
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        sources = saved?.sources ?? []
        selectedID = saved?.selectedID
        if !sources.contains(where: { $0.id == selectedID }) { selectedID = nil }
        reload()
        testRouteLatencies()
    }

    func testRouteLatencies() {
        for source in sources where source.kind == .emby {
            verifyEmbyConnection(source.id)
        }
    }

    func addDeviceSource(kind: MediaSource.Kind, name: String, bookmark: Data? = nil) {
        guard kind == .local || kind == .photos, !sources.contains(where: { $0.kind == kind }) else { return }
        let source = MediaSource(id: UUID(), name: name, kind: kind, folderBookmark: bookmark, behavior: .empty)
        sources.append(source)
        if selectedID == nil { selectedID = source.id; reload() }
        persist()
    }

    /// Register imported files without changing the user's selected source.
    func registerImportedVideos(name: String) {
        if let index = sources.firstIndex(where: { $0.kind == .local }) {
            sources[index].folderBookmark = nil
        } else {
            sources.append(MediaSource(id: UUID(), name: name, kind: .local, behavior: .empty))
        }
        persist()
        reload()
    }

    func addDemo(name: String, behavior: DemoSourceBehavior) {
        let source = MediaSource(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                 kind: .demo, behavior: behavior)
        guard !source.name.isEmpty else { return }
        sources.append(source)
        if selectedID == nil { selectedID = source.id; reload() }
        persist()
    }

    func select(_ id: UUID) {
        guard sources.contains(where: { $0.id == id }) else { return }
        let didSwitchSource = selectedID != id
        selectedID = id
        if didSwitchSource { verifyEmbyConnection(id) }
        embyParentStack.removeAll()
        currentEmbyParentID = nil
        hasMoreEmbyItems = false
        persist()
        reload()
    }

    func open(_ item: MediaItem) {
        guard item.isContainer, selectedSource?.kind == .emby else { return }
        guard case .loaded(let current) = content else { return }
        embyParentStack.append((item, current, hasMoreEmbyItems))
        currentEmbyParentID = item.embyItemID
        hasMoreEmbyItems = false
        loadEmbyItems(parentID: item.embyItemID)
    }

    func navigateEmbyBack() {
        request?.cancel(); moreRequest?.cancel()
        generation = UUID(); loadingMore = false; paginationError = nil
        guard let previous = embyParentStack.popLast() else { return }
        currentEmbyParentID = embyParentStack.last?.0.embyItemID
        content = .loaded(previous.1)
        hasMoreEmbyItems = previous.2
    }

    func loadMoreEmbyItems() {
        guard case .loaded(let current) = content, let source = selectedSource,
              source.kind == .emby, hasMoreEmbyItems, !loadingMore, currentEmbyParentID != nil else { return }
        let token = generation
        let parentID = currentEmbyParentID
        loadingMore = true; paginationError = nil
        moreRequest = Task {
            defer { if generation == token { loadingMore = false } }
            do {
                let next = try await EmbyRepository.shared.items(for: source, parentID: parentID,
                                                                  startIndex: current.count)
                guard generation == token, selectedID == source.id,
                      case .loaded(let latest) = content else { return }
                let seen = Set(latest.map(\.id))
                content = .loaded(latest + next.filter { !seen.contains($0.id) })
                hasMoreEmbyItems = next.count >= 100
            } catch {
                if !Task.isCancelled, generation == token { paginationError = error.localizedDescription }
            }
        }
    }

    func embyConfiguration(for id: UUID) -> EmbySourceConfiguration? {
        guard var configuration = sources.first(where: { $0.id == id })?.emby else { return nil }
        configuration.customHeaders = EmbyAccountStore.shared.customHeaders(sourceID: id)
        return configuration
    }

    func saveEmby(_ id: UUID?, configuration: EmbySourceConfiguration, password: String?) async throws {
        let original = id.flatMap { id in sources.first { $0.id == id && $0.kind == .emby } }
        let sourceID = id ?? UUID()
        var candidate = original ?? MediaSource(id: sourceID, name: configuration.title, kind: .emby,
                                                behavior: .empty, emby: configuration)
        let preferredAddress = configuration.serverAddress
        var validated = configuration
        validated.serverAddress = configuration.primaryRoute
        candidate.emby = validated
        let accounts = EmbyAccountStore.shared
        let serverName: String?
        let preparedAccount: EmbyAccount?
        if let password {
            let (auth, account) = try await accounts.prepareAuthentication(
                source: candidate, username: validated.username, password: password
            )
            validated.serverID = auth.serverID
            validated.userID = auth.userID
            serverName = auth.serverName
            preparedAccount = account
        } else {
            guard validated.username == original?.emby?.username else { throw EmbyError.authentication }
            serverName = try await accounts.verifyConnection(for: candidate)
            preparedAccount = nil
        }
        if validated.title.isEmpty {
            validated.title = serverName.flatMap { $0.isEmpty ? nil : $0 }
                ?? URLComponents(string: validated.primaryRoute)?.host ?? "Emby"
        }
        if validated.fetchAlternateAddresses == true {
            let client: EmbyAPIClient
            if let preparedAccount {
                client = try EmbyAPIClient(configuration: validated, token: preparedAccount.token,
                                           deviceID: preparedAccount.deviceID)
            } else {
                client = try accounts.client(for: candidate)
            }
            let routes = try await EmbyRepository.alternateRoutes(client: client, primaryRoute: validated.primaryRoute)
            validated.mergeServerRoutes(routes)
        }
        let index = id.flatMap { id in sources.firstIndex { $0.id == id && $0.kind == .emby } }
        guard id == nil || index != nil else { throw EmbyError.missingAccount }
        if (original == nil || original?.emby?.serverID == validated.serverID),
           let preferred = validated.backupRoutes.first(where: {
            EmbyRouteOptions.key($0) == EmbyRouteOptions.key(preferredAddress)
        }) {
            validated.primaryRouteAddress = validated.primaryRoute
            validated.serverAddress = preferred
        }
        if let preparedAccount { try accounts.save(preparedAccount, sourceID: sourceID) }
        validated.customHeaders = [:]
        candidate.name = validated.title
        candidate.emby = validated
        if let index { sources[index] = candidate }
        else { sources.append(candidate) }
        if selectedID == nil { selectedID = sourceID }
        connectionChecks.removeValue(forKey: sourceID)?.cancel()
        connectionGenerations[sourceID] = nil
        connectionStatuses[sourceID] = nil
        routeLatencies[sourceID] = nil
        if let oldAddress = original?.emby?.serverAddress,
           EmbyRouteOptions.key(oldAddress) != EmbyRouteOptions.key(validated.serverAddress) {
            verifyEmbyConnection(sourceID)
        }
        persist()
        if selectedID == sourceID { reload() }
    }

    /// Route selection is immediate; verification only updates its status icon.
    func switchEmbyRoute(_ id: UUID, address: String) {
        guard let index = sources.firstIndex(where: { $0.id == id && $0.kind == .emby }),
              var configuration = sources[index].emby else { return }
        guard EmbyRouteOptions.key(address) != EmbyRouteOptions.key(configuration.serverAddress) else {
            verifyEmbyConnection(id)
            return
        }
        let orderedRoutes = [configuration.primaryRoute] + configuration.backupRoutes
        configuration.primaryRouteAddress = configuration.primaryRoute
        configuration.serverAddress = address
        configuration.alternateAddresses = EmbyRouteOptions.unique(orderedRoutes)
        sources[index].emby = configuration
        verifyEmbyConnection(id)
        persist()
        if selectedID == id { reload() }
    }

    func refreshEmbyRoutes(_ id: UUID) async throws {
        guard let source = sources.first(where: { $0.id == id }),
              let original = source.emby else { return }
        try await EmbyAccountStore.shared.verifyConnection(for: source)
        let routes = try await EmbyRepository.shared.alternateRoutes(for: source)
        try Task.checkCancellation()

        guard let index = sources.firstIndex(where: { $0.id == id }),
              var configuration = sources[index].emby,
              configuration.primaryRoute == original.primaryRoute,
              configuration.serverID == original.serverID,
              configuration.userID == original.userID else { return }
        let oldAddress = configuration.serverAddress
        configuration.replaceServerRoutes(routes)
        sources[index].emby = configuration
        persist()
        if oldAddress != configuration.serverAddress {
            verifyEmbyConnection(id)
            if selectedID == id { reload() }
        }
    }

    func configure(_ id: UUID, behavior: DemoSourceBehavior) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].behavior = behavior
        persist()
        if selectedID == id { reload() }
    }

    func remove(_ id: UUID) {
        routeLatencies[id] = nil
        connectionChecks.removeValue(forKey: id)?.cancel()
        connectionGenerations[id] = nil
        connectionStatuses[id] = nil
        if let source = sources.first(where: { $0.id == id }), source.kind == .emby {
            EmbyAccountStore.shared.logout(source: source)
        }
        sources.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil; reload() }
        persist()
    }

    private func loadEmbyItems(parentID: String?) {
        request?.cancel()
        isLoadingEmbyHome = false
        moreRequest?.cancel(); loadingMore = false; paginationError = nil
        generation = UUID()
        let token = generation
        guard let source = selectedSource else { return }
        content = .loading
        request = Task { [weak self] in
            do {
                let items = try await EmbyRepository.shared.items(for: source, parentID: parentID, startIndex: 0)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.content = .loaded(items)
                self.hasMoreEmbyItems = items.count >= 100
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.content = .failed(.message(error.localizedDescription))
            }
        }
    }

    private func loadEmbyMediaGroups(fullRendering: Bool) {
        request?.cancel()
        moreRequest?.cancel()
        loadingMore = false
        paginationError = nil
        generation = UUID()
        let token = generation
        guard let source = selectedSource, source.kind == .emby else { return }
        let scope = AppCacheStore.scope(for: source)
        var previous = embyHome?.scope == scope ? embyHome : nil
        if ImageCacheDebugSettings.ignoresLocalCache, var home = previous {
            home.artwork = nil
            home.featuredArtwork = nil
            previous = home
        }
        isLoadingEmbyHome = true
        embyHome = fullRendering ? nil : previous
        content = embyHome == nil ? .loading : .loaded([])

        request = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == token { isLoadingEmbyHome = false }
            }
            let repository = EmbyRepository.shared
            let cache = AppCacheStore.shared
            let cacheGeneration = await cache.libraryGeneration
            do {
                let libraries = try await repository.mediaLibraries(for: source)
                let cachedFeatured = await cache.items(scope: scope, key: "featured:titles")
                let featured = previous?.featured ?? cachedFeatured ?? []
                try Task.checkCancellation()
                guard generation == token else { return }

                var groups = [EmbyMediaGroup(id: EmbyMediaGroup.librariesID, title: "我的媒体", items: libraries)]
                groups += libraries.map {
                    EmbyMediaGroup(id: $0.id.localID, title: $0.title, items: [], isLoading: true)
                }
                if !fullRendering {
                    embyHome = EmbyHome(scope: scope, groups: groups, featured: previous?.featured ?? [],
                                        featuredArtwork: previous?.featuredArtwork)
                    content = .loaded([])
                    isLoadingEmbyHome = false
                }
                await cache.save(libraries, scope: scope, key: "libraries:media-only", generation: cacheGeneration)
                await withTaskGroup(of: (Int, EmbyMediaGroup).self) { tasks in
                    for (index, library) in libraries.enumerated() {
                        tasks.addTask {
                            let id = library.id.localID
                            let key = "latest:titles:\(id)"
                            var group = EmbyMediaGroup(id: id, title: library.title, items: [])
                            do {
                                let result = try await repository.latestMediaGroup(for: source, libraryID: id)
                                group.items = result.items
                                group.totalCount = result.totalCount
                                try Task.checkCancellation()
                                await cache.save(group.items, scope: scope, key: key, generation: cacheGeneration)
                            } catch {
                                group.items = await cache.items(scope: scope, key: key) ?? []
                                group.errorMessage = error.localizedDescription
                            }
                            return (index + 1, group)
                        }
                    }
                    for await (index, group) in tasks {
                        guard !Task.isCancelled, generation == token else {
                            tasks.cancelAll()
                            break
                        }
                        groups[index] = group
                        if !fullRendering { embyHome?.groups[index] = group }
                    }
                }

                let sampledFeatured = EmbyMediaGroup.featured(in: groups)
                await cache.save(sampledFeatured, scope: scope, key: "featured:titles", generation: cacheGeneration)
                async let carouselPreparation = prepareCarousel(sampledFeatured, source: source, token: token, publish: !fullRendering)

                if fullRendering {
                    try Task.checkCancellation()
                    let featuredArtwork = await carouselPreparation
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    embyHome = EmbyHome(scope: scope, groups: groups,
                                        featured: sampledFeatured.filter { featuredArtwork[$0.id] != nil },
                                        featuredArtwork: featuredArtwork)
                    content = .loaded([])
                } else {
                    _ = await carouselPreparation
                }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                if !fullRendering, previous == nil,
                   let cachedLibraries = await cache.items(scope: scope, key: "libraries:media-only") {
                    var cachedGroups = [EmbyMediaGroup(id: EmbyMediaGroup.librariesID, title: "我的媒体", items: cachedLibraries)]
                    for library in cachedLibraries {
                        let items = await cache.items(scope: scope, key: "latest:titles:\(library.id.localID)") ?? []
                        cachedGroups.append(EmbyMediaGroup(id: library.id.localID, title: library.title, items: items))
                    }
                    let cachedFeatured = await cache.items(scope: scope, key: "featured:titles") ?? EmbyMediaGroup.featured(in: cachedGroups)
                    guard !Task.isCancelled, generation == token else { return }
                    embyHome = EmbyHome(scope: scope, groups: cachedGroups, featured: [])
                    content = .loaded([])
                    isLoadingEmbyHome = false
                    _ = await prepareCarousel(cachedFeatured, source: source, token: token, publish: true)
                }
                if embyHome == nil { content = .failed(.message(error.localizedDescription)) }
            }
        }
    }

    private func prepareCarousel(
        _ items: [MediaItem], source: MediaSource, token: UUID, publish: Bool
    ) async -> [MediaID: EmbyFeaturedArtwork] {
        let artwork = await MediaThumbnailLoader.shared.prepareCarouselArtwork(items, source: source) { [weak self] id, image in
            guard publish, let self, !Task.isCancelled, generation == token, var home = embyHome else { return }
            var prepared = home.featuredArtwork ?? [:]
            prepared[id] = image
            home.featuredArtwork = prepared
            home.featured = items.filter { prepared[$0.id] != nil }
            embyHome = home
        }
        if publish, !Task.isCancelled, generation == token, var home = embyHome {
            home.featured = items.filter { artwork[$0.id] != nil }
            home.featuredArtwork = artwork
            embyHome = home
        }
        return artwork
    }

    func reload() {
        refreshGeneration += 1
        if selectedSource?.kind == .emby, let parentID = currentEmbyParentID {
            loadEmbyItems(parentID: parentID)
            return
        }
        if selectedSource?.kind == .emby {
            loadEmbyMediaGroups(fullRendering: defaults.bool(forKey: EmbyBrowsingSettings.fullRenderingKey))
            return
        }
        request?.cancel()
        moreRequest?.cancel(); loadingMore = false; paginationError = nil
        let token = UUID()
        generation = token
        isLoadingEmbyHome = false
        embyHome = nil
        guard let source = selectedSource else { content = .unselected; return }
        content = .loading
        let adapter = adapter
        request = Task { [weak self] in
            do {
                let items = try await adapter.media(in: source)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.content = .loaded(items)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.content = .failed(error as? SourceFailure ?? .message(error.localizedDescription))
            }
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(Snapshot(sources: sources, selectedID: selectedID))
            defaults.set(data, forKey: Self.storageKey)
            storageFailed = false
        } catch { storageFailed = true }
    }
}

enum AppCacheCategory: String, CaseIterable, Hashable, Sendable {
    case library, images, videos, subtitles, danmaku, other
}

actor AppCacheStore {
    static let shared = AppCacheStore()
    private let directory = URL.cachesDirectory.appending(path: "VesperCache-v1", directoryHint: .isDirectory)
    private var migrated = false
    private var imageGeneration = UUID()
    private(set) var libraryGeneration = UUID()
    private var writes: [AppCacheCategory: Int] = [:]

    nonisolated static func scope(for source: MediaSource) -> String {
        "\(source.id)|\(source.emby?.serverAddress ?? "")|\(source.emby?.userID ?? "")|\(source.emby?.username ?? "")"
    }

    nonisolated static func embyArtworkKey(for item: MediaItem, source: MediaSource) -> String {
        let key = "artwork|\(scope(for: source))|\(item.id.localID)|\(item.imageURL?.absoluteString ?? "")"
        if item.embyItemType == "Episode" {
            return "episode-preview|\(key)|\(item.previewImageURL?.absoluteString ?? "")"
        }
        return item.fallbackImageURL.map { "\(key)|\($0.absoluteString)" } ?? key
    }

    func items(scope: String, key: String) -> [MediaItem]? {
        migrateIfNeeded()
        return read("items|\(scope)|\(key)", category: .library)
            .flatMap { try? JSONDecoder().decode([MediaItem].self, from: $0) }
    }

    func save(_ items: [MediaItem], scope: String, key: String, generation: UUID) {
        guard generation == libraryGeneration, items.allSatisfy({ $0.resource == nil }),
              let data = try? JSONEncoder().encode(items) else { return }
        migrateIfNeeded()
        write(data, key: "items|\(scope)|\(key)", category: .library)
    }

    func image(key: String) -> (Data?, UUID) {
        migrateIfNeeded()
        return (read("image|\(key)", category: .images), imageGeneration)
    }

    func image(key: String, ignoringLocalCache: Bool) -> (Data?, UUID) {
        if ignoringLocalCache { return (nil, imageGeneration) }
        migrateIfNeeded()
        return (read("image|\(key)", category: .images), imageGeneration)
    }

    func invalidateImageWrites() { imageGeneration = UUID() }

    func saveImage(_ data: Data, key: String, generation: UUID) {
        guard generation == imageGeneration else { return }
        write(data, key: "image|\(key)", category: .images)
    }

    func sizes() -> [AppCacheCategory: Int64] {
        migrateIfNeeded()
        return Dictionary(uniqueKeysWithValues: AppCacheCategory.allCases.map { category in
            (category, files(in: folder(category)).reduce(0) { $0 + $1.bytes })
        })
    }

    func clear(_ categories: Set<AppCacheCategory>) -> Set<AppCacheCategory> {
        migrateIfNeeded()
        if categories.contains(.images) { imageGeneration = UUID() }
        if categories.contains(.library) { libraryGeneration = UUID() }
        var failures = Set<AppCacheCategory>()
        for category in categories {
            do {
                try FileManager.default.removeItem(at: folder(category))
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                continue
            } catch {
                failures.insert(category)
            }
        }
        return failures
    }

    private func folder(_ category: AppCacheCategory) -> URL {
        directory.appending(path: category.rawValue, directoryHint: .isDirectory)
    }

    private func file(_ key: String, category: AppCacheCategory) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder(category).appending(path: digest)
    }

    private func read(_ key: String, category: AppCacheCategory) -> Data? {
        try? Data(contentsOf: file(key, category: category))
    }

    private func write(_ data: Data, key: String, category: AppCacheCategory) {
        guard data.count <= 8 * 1024 * 1024 else { return }
        try? FileManager.default.createDirectory(at: folder(category), withIntermediateDirectories: true)
        try? data.write(to: file(key, category: category), options: .atomic)
        writes[category, default: 0] += 1
        if writes[category] == 1 || writes[category, default: 0].isMultiple(of: 32) {
            trim(category, limit: (category == .images ? 128 : 32) * 1024 * 1024)
        }
    }

    private func files(in folder: URL) -> [(url: URL, bytes: Int64, date: Date)] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return [] }
        var entries: [(URL, Int64, Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            entries.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        return entries
    }

    private func trim(_ category: AppCacheCategory, limit: Int64) {
        let entries = files(in: folder(category))
        var bytes = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries.sorted(by: { $0.date < $1.date }) where bytes > limit {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { bytes -= entry.bytes }
        }
    }

    private func migrateIfNeeded() {
        guard !migrated else { return }
        migrated = true
        let legacy = URL.cachesDirectory.appending(path: "EmbyMedia-v1", directoryHint: .isDirectory)
        let manager = FileManager.default
        for entry in files(in: legacy) {
            guard let handle = try? FileHandle(forReadingFrom: entry.url) else { continue }
            let firstByte = try? handle.read(upToCount: 1)
            try? handle.close()
            let category: AppCacheCategory = firstByte?.first == 91 ? .library : .images
            let folder = folder(category)
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appending(path: entry.url.lastPathComponent)
                if manager.fileExists(atPath: target.path) {
                    try manager.removeItem(at: entry.url)
                } else {
                    try manager.moveItem(at: entry.url, to: target)
                }
            } catch {
                // The old entry can be migrated on the next launch.
            }
        }
        if (try? manager.contentsOfDirectory(atPath: legacy.path).isEmpty) == true {
            try? manager.removeItem(at: legacy)
        }
    }
}
