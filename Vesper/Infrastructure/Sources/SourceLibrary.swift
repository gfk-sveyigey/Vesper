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
    var embyMediaSourceID: String? = nil
    var imageURL: URL? = nil
    var duration: Double? = nil
    var resumePosition: Double? = nil
    var dateCreated: Date? = nil
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
    @Published private(set) var selectedID: UUID?
    @Published private(set) var content: ContentState = .unselected
    @Published private(set) var storageFailed = false
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
    @Published private(set) var embyMediaGroups: [EmbyMediaGroup] = []
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
        selectedID = id
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

    func addEmby(configuration: EmbySourceConfiguration, password: String) async throws {
        let fallbackName = configuration.title.isEmpty ? Self.embyHostName(configuration.serverAddress) : configuration.title
        let source = MediaSource(id: UUID(), name: fallbackName, kind: .emby,
                                 behavior: .empty, emby: configuration)
        let auth = try await EmbyAccountStore.shared.authenticate(source: source, username: configuration.username,
                                                                  password: password)
        var authenticated = source
        authenticated.emby?.serverID = auth.serverID
        authenticated.emby?.userID = auth.userID
        if configuration.title.isEmpty, let name = auth.serverName, !name.isEmpty {
            authenticated.name = name
            authenticated.emby?.title = name
        }
        authenticated.emby?.customHeaders = [:]
        sources.append(authenticated)
        if selectedID == nil { selectedID = source.id; reload() }
        persist()
    }

    private static func embyHostName(_ address: String) -> String {
        URLComponents(string: address)?.host ?? "Emby"
    }

    func updateEmby(_ id: UUID, configuration: EmbySourceConfiguration, password: String?) async throws {
        guard let index = sources.firstIndex(where: { $0.id == id && $0.kind == .emby }) else { return }
        _ = try EmbyAPIClient(configuration: configuration, token: nil, deviceID: "validation")
        var updated = sources[index]
        updated.name = configuration.title
        updated.emby = configuration
        if let password, !password.isEmpty {
            let auth = try await EmbyAccountStore.shared.authenticate(source: updated, username: configuration.username,
                                                                      password: password)
            updated.emby?.serverID = auth.serverID
            updated.emby?.userID = auth.userID
        } else {
            try EmbyAccountStore.shared.updateCustomHeaders(configuration.customHeaders, sourceID: id)
        }
        updated.emby?.customHeaders = [:]
        guard let currentIndex = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[currentIndex] = updated
        persist()
        if selectedID == id { reload() }
    }

    func configure(_ id: UUID, behavior: DemoSourceBehavior) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].behavior = behavior
        persist()
        if selectedID == id { reload() }
    }

    func remove(_ id: UUID) {
        if let source = sources.first(where: { $0.id == id }), source.kind == .emby {
            EmbyAccountStore.shared.logout(source: source)
        }
        sources.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil; reload() }
        persist()
    }

    private func loadEmbyItems(parentID: String?) {
        request?.cancel()
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

    private func loadEmbyMediaGroups() {
        request?.cancel()
        moreRequest?.cancel(); loadingMore = false; paginationError = nil
        generation = UUID()
        let token = generation
        guard let source = selectedSource, source.kind == .emby else { return }
        embyMediaGroups = []
        content = .loading
        request = Task { [weak self] in
            do {
                let repository = EmbyRepository.shared
                let cache = AppCacheStore.shared
                let scope = AppCacheStore.scope(for: source)
                let cacheGeneration = await cache.libraryGeneration
                func groups(for libraries: [MediaItem]) async -> [EmbyMediaGroup] {
                    var groups = [EmbyMediaGroup(id: EmbyMediaGroup.librariesID, title: "我的媒体", items: libraries)]
                    for library in libraries {
                        let id = library.id.localID
                        let items = await cache.items(scope: scope, key: "latest:\(id)") ?? []
                        groups.append(EmbyMediaGroup(id: id, title: library.title, items: items, isLoading: items.isEmpty))
                    }
                    return groups
                }
                if let cached = await cache.items(scope: scope, key: "libraries") {
                    let groups = await groups(for: cached)
                    guard !Task.isCancelled, let self, self.generation == token else { return }
                    self.embyMediaGroups = groups
                    self.content = .loaded([])
                }
                let libraries = try await repository.mediaLibraries(for: source)
                let initialGroups = await groups(for: libraries)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.embyMediaGroups = initialGroups
                self.content = .loaded([])
                await cache.save(libraries, scope: scope, key: "libraries", generation: cacheGeneration)
                await withTaskGroup(of: EmbyMediaGroup.self) { tasks in
                    for library in libraries {
                        tasks.addTask {
                            let id = library.id.localID
                            do {
                                let items = try await repository.latestMedia(for: source, libraryID: id)
                                return EmbyMediaGroup(id: id, title: library.title, items: items)
                            } catch {
                                return EmbyMediaGroup(id: id, title: library.title, items: [],
                                                      errorMessage: error.localizedDescription)
                            }
                        }
                    }
                    for await group in tasks {
                        guard !Task.isCancelled, self.generation == token else {
                            tasks.cancelAll()
                            break
                        }
                        if let index = self.embyMediaGroups.firstIndex(where: { $0.id == group.id }) {
                            if let error = group.errorMessage {
                                self.embyMediaGroups[index].isLoading = false
                                self.embyMediaGroups[index].errorMessage = error
                            } else {
                                self.embyMediaGroups[index] = group
                                await cache.save(group.items, scope: scope, key: "latest:\(group.id)", generation: cacheGeneration)
                            }
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                if self.embyMediaGroups.isEmpty {
                    self.content = .failed(.message(error.localizedDescription))
                } else {
                    for index in self.embyMediaGroups.indices where self.embyMediaGroups[index].isLoading {
                        self.embyMediaGroups[index].isLoading = false
                        self.embyMediaGroups[index].errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func reload() {
        if selectedSource?.kind == .emby, let parentID = currentEmbyParentID {
            loadEmbyItems(parentID: parentID)
            return
        }
        if selectedSource?.kind == .emby {
            loadEmbyMediaGroups()
            return
        }
        request?.cancel()
        moreRequest?.cancel(); loadingMore = false; paginationError = nil
        let token = UUID()
        generation = token
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
