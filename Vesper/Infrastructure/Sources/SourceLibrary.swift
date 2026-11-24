import Foundation
import Combine

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
    @Published private(set) var protectedSourceIDs: Set<UUID> = []
    @Published private(set) var isPrivacyModeEnabled = false

    var canUsePrivacyMode: Bool { AppLock.shared.protectsSources }

    func refreshProtectionScope() {
        guard !canUsePrivacyMode else { return }
        protectedSourceIDs.removeAll()
        defaults.removeObject(forKey: Self.protectedSourceIDsKey)
        isPrivacyModeEnabled = false
    }

    var visibleSources: [MediaSource] {
        sources.filter { !canUsePrivacyMode || isPrivacyModeEnabled || !isProtected($0) }
    }

    func isProtected(_ source: MediaSource) -> Bool { canUsePrivacyMode && protectedSourceIDs.contains(source.id) }

    func setProtected(_ protected: Bool, for source: MediaSource) {
        guard canUsePrivacyMode else { return }
        if protected { protectedSourceIDs.insert(source.id) }
        else { protectedSourceIDs.remove(source.id) }
        defaults.set(protectedSourceIDs.map(\.uuidString), forKey: Self.protectedSourceIDsKey)
        if !isPrivacyModeEnabled, selectedID == source.id, protected {
            selectedID = visibleSources.first?.id
            reload()
        }
    }

    func setPrivacyMode(_ enabled: Bool) {
        guard AppLock.shared.protectsSources || !enabled else { return }
        guard enabled != isPrivacyModeEnabled else { return }
        isPrivacyModeEnabled = enabled
        if !enabled {
            for id in protectedSourceIDs {
                connectionChecks.removeValue(forKey: id)?.cancel()
                connectionGenerations[id] = nil
            }
        }
        if !enabled, let selectedID, protectedSourceIDs.contains(selectedID) {
            self.selectedID = visibleSources.first?.id
            content = .unselected
            embyHome = nil
            persist()
            reload()
        }
    }

    func testProtectedRouteLatencies() {
        guard isPrivacyModeEnabled else { return }
        for source in visibleSources where protectedSourceIDs.contains(source.id) && source.kind == .emby {
            verifyEmbyConnection(source.id)
        }
    }

    func moveSources(from offsets: IndexSet, to destination: Int) {
        let visible = visibleSources
        guard !offsets.isEmpty, offsets.allSatisfy({ visible.indices.contains($0) }),
              (0...visible.count).contains(destination) else { return }
        let moved = offsets.map { visible[$0] }
        var ordered = visible.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        ordered.insert(contentsOf: moved, at: destination - offsets.filter { $0 < destination }.count)
        var iterator = ordered.makeIterator()
        sources = sources.map { source in
            !canUsePrivacyMode || isPrivacyModeEnabled || !isProtected(source) ? iterator.next()! : source
        }
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
        if canUsePrivacyMode, !isPrivacyModeEnabled,
           let source = sources.first(where: { $0.id == id }), isProtected(source) { return }
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
    var catalog: any MediaSourceCatalogService { MediaSourceServices.catalog }
    var seriesCatalog: any SeriesMediaCatalogService { MediaSourceServices.seriesCatalog }
    var artwork: any MediaSourceArtworkService { MediaSourceServices.artwork }

    private let adapter: any SourceAdapter
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private static let storageKey = "sources.snapshot.v1"
    private static let protectedSourceIDsKey = "sources.protectedIDs.v1"
    struct EmbyHome {
        let scope: String
        var groups: [EmbyMediaGroup]
        var featured: [MediaItem]
        var featuredArtwork: [MediaID: EmbyFeaturedArtwork]? = nil
    }

    @Published private(set) var embyHome: EmbyHome?
    @Published private(set) var isLoadingEmbyHome = false
    private static var didRunColdStartRouteTest = false

    var selectedSource: MediaSource? { sources.first { $0.id == selectedID } }

    init(defaults: UserDefaults = .standard, adapter: any SourceAdapter = DeviceSourceAdapter()) {
        self.defaults = defaults
        self.adapter = adapter
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        sources = saved?.sources ?? []
        protectedSourceIDs = Set((defaults.stringArray(forKey: Self.protectedSourceIDsKey) ?? [])
            .compactMap(UUID.init(uuidString:))).intersection(Set(sources.map(\.id)))
        selectedID = saved?.selectedID
        if let id = selectedID, protectedSourceIDs.contains(id) { selectedID = visibleSources.first?.id }
        if !sources.contains(where: { $0.id == selectedID }) { selectedID = nil }
        reload()
        if !Self.didRunColdStartRouteTest {
            Self.didRunColdStartRouteTest = true
            testRouteLatencies()
        }
    }

    func testRouteLatencies() {
        for source in visibleSources where source.kind == .emby {
            verifyEmbyConnection(source.id)
        }
    }

    func addDeviceSource(kind: MediaSource.Kind, name: String, bookmark: Data? = nil) {
        guard kind == .local || kind == .photos, !sources.contains(where: { $0.kind == kind }) else { return }
        let source = MediaSource(id: UUID(), name: name, kind: kind, folderBookmark: bookmark)
        sources.append(source)
        if selectedID == nil { selectedID = source.id; reload() }
        persist()
    }

    /// Register imported files without changing the user's selected source.
    func registerImportedVideos(name: String) {
        if let index = sources.firstIndex(where: { $0.kind == .local }) {
            sources[index].folderBookmark = nil
        } else {
            sources.append(MediaSource(id: UUID(), name: name, kind: .local))
        }
        persist()
        reload()
    }

    func select(_ id: UUID) {
        guard visibleSources.contains(where: { $0.id == id }) else { return }
        let didSwitchSource = selectedID != id
        selectedID = id
        if didSwitchSource { verifyEmbyConnection(id) }
        persist()
        reload()
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
                                                emby: configuration)
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

    func updateEmbyIcon(_ id: UUID, iconData: Data?) {
        guard let index = sources.firstIndex(where: { $0.id == id }),
              var configuration = sources[index].emby else { return }
        configuration.iconData = iconData
        sources[index].emby = configuration
        persist()
    }

    func updateEmbyRoutes(_ id: UUID, routes: [EmbyRouteDraft]) throws {
        guard let index = sources.firstIndex(where: { $0.id == id }),
              var configuration = sources[index].emby,
              let primary = routes.first,
              routes.allSatisfy({ isValidEmbyRoute($0.address) }) else {
            throw EmbyError.invalidAddress
        }
        let oldAddress = configuration.serverAddress
        let oldAddressKey = EmbyRouteOptions.key(oldAddress)
        let activeRoute = routes.first(where: { EmbyRouteOptions.key($0.address) == oldAddressKey })
            ?? (oldAddressKey == EmbyRouteOptions.key(configuration.primaryRoute) ? routes.first : nil)
        guard let activeRoute else { throw EmbyError.invalidAddress }
        configuration.primaryRouteAddress = primary.address
        configuration.serverAddress = activeRoute.address
        configuration.alternateAddresses = EmbyRouteOptions.unique(routes.map(\.address))
        configuration.serverRouteAddresses = routes.filter(\.fromServer).map(\.address)
        configuration.alternateRouteNames = Dictionary(
            routes.filter { !$0.name.isEmpty }.map { (EmbyRouteOptions.key($0.address), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        sources[index].emby = configuration
        persist()
        if oldAddressKey != EmbyRouteOptions.key(configuration.serverAddress) {
            verifyEmbyConnection(id)
            if selectedID == id { reload() }
        }
    }

    private func isValidEmbyRoute(_ address: String) -> Bool {
        (try? EmbyAPIClient(configuration: .init(title: "", note: "", serverAddress: address, username: ""),
                            token: nil, deviceID: "route-validation")) != nil
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

    func remove(_ id: UUID) {
        routeLatencies[id] = nil
        connectionChecks.removeValue(forKey: id)?.cancel()
        connectionGenerations[id] = nil
        connectionStatuses[id] = nil
        if let source = sources.first(where: { $0.id == id }), source.kind == .emby {
            EmbyAccountStore.shared.logout(source: source)
        }
        sources.removeAll { $0.id == id }
        protectedSourceIDs.remove(id)
        defaults.set(protectedSourceIDs.map(\.uuidString), forKey: Self.protectedSourceIDsKey)
        if selectedID == id { selectedID = nil; reload() }
        persist()
    }

    private func loadEmbyMediaGroups(fullRendering: Bool) {
        request?.cancel()
        generation = UUID()
        let token = generation
        guard let source = selectedSource, source.kind == .emby else { return }
        let scope = AppCacheStore.scope(for: source)
        var previous = embyHome?.scope == scope ? embyHome : nil
        if ImageCacheDebugSettings.ignoresLocalCache, var home = previous {
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
        if selectedSource?.kind == .emby {
            loadEmbyMediaGroups(fullRendering: defaults.bool(forKey: EmbyBrowsingSettings.fullRenderingKey))
            return
        }
        request?.cancel()
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
