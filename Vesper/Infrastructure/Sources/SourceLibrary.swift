import Foundation
import Combine
import Photos
import UniformTypeIdentifiers

/// Stable identity is scoped to a source, not a title or display URL.
struct MediaID: Hashable, Codable, Sendable {
    let sourceID: UUID
    let localID: String
}

enum PlayableResource: Hashable, Sendable {
    case file(URL)
    case photoAsset(String)
}

struct MediaItem: Identifiable, Hashable, Sendable {
    let id: MediaID
    let title: String
    let resource: PlayableResource
}

struct SourceCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let browse = Self(rawValue: 1 << 0)
    static let playback = Self(rawValue: 1 << 1)
}

struct MediaSource: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case photos, local
        var titleKey: String { self == .photos ? "相册视频" : "本地视频" }
        var symbol: String { self == .photos ? "photo.on.rectangle" : "folder" }
    }
    let id: UUID
    let kind: Kind
    var capabilities: SourceCapabilities { [.browse] }
}

enum SourceFailure: Error, Equatable {
    case unavailable, permissionDenied, importFailed
    var messageKey: String {
        switch self {
        case .unavailable: "无法加载来源"
        case .permissionDenied: "请在系统设置中允许访问相册视频。"
        case .importFailed: "视频导入失败，请检查文件是否可用及剩余空间。"
        }
    }
}

protocol SourceAdapter: Sendable {
    func media(in source: MediaSource) async throws -> [MediaItem]
}

struct DeviceSourceAdapter: SourceAdapter {
    let localDirectory: URL

    func media(in source: MediaSource) async throws -> [MediaItem] {
        switch source.kind {
        case .photos:
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else { throw SourceFailure.permissionDenied }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: .video, options: options)
            var items: [MediaItem] = []
            for index in 0..<assets.count {
                try Task.checkCancellation()
                let asset = assets.object(at: index)
                let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? asset.localIdentifier
                items.append(MediaItem(id: MediaID(sourceID: source.id, localID: asset.localIdentifier),
                                       title: name, resource: .photoAsset(asset.localIdentifier)))
            }
            return items
        case .local:
            let manager = FileManager.default
            guard manager.fileExists(atPath: localDirectory.path) else { return [] }
            var failed = false
            guard let files = manager.enumerator(at: localDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return false }) else {
                throw SourceFailure.unavailable
            }
            var items: [MediaItem] = []
            for case let url as URL in files {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
                guard values.isRegularFile == true, values.contentType?.conforms(to: .movie) == true else { continue }
                let relative = String(url.path.dropFirst(localDirectory.path.count))
                items.append(MediaItem(id: MediaID(sourceID: source.id, localID: relative),
                                       title: url.lastPathComponent, resource: .file(url)))
            }
            if failed { throw SourceFailure.unavailable }
            return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    /// Copies into an owned directory so access survives picker dismissal/relaunch.
    /// A failed batch rolls back only its new files, never existing videos.
    static func importVideos(_ urls: [URL], into directory: URL) throws {
        let manager = FileManager.default
        let batch = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: batch, withIntermediateDirectories: true)
        do {
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
                guard values.isRegularFile == true, values.contentType?.conforms(to: .movie) == true else {
                    throw SourceFailure.importFailed
                }
                let folder = batch.appendingPathComponent(String(index), isDirectory: true)
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                try manager.copyItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
            }
        } catch {
            try? manager.removeItem(at: batch)
            throw error
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
    @Published private(set) var isImporting = false
    private let defaults: UserDefaults
    private let adapter: any SourceAdapter
    private let localDirectory: URL
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private static let storageKey = "sources.device.v1"

    var selectedSource: MediaSource? { sources.first { $0.id == selectedID } }
    func contains(_ kind: MediaSource.Kind) -> Bool { sources.contains { $0.kind == kind } }

    init(defaults: UserDefaults = .standard, adapter: (any SourceAdapter)? = nil, localDirectory: URL? = nil) {
        self.defaults = defaults
        let directory = localDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Videos", isDirectory: true)
        self.localDirectory = directory
        self.adapter = adapter ?? DeviceSourceAdapter(localDirectory: directory)
        // The previous snapshot contained only demo data and is deliberately discarded.
        defaults.removeObject(forKey: "sources.snapshot.v1")
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) }
        var kinds = Set<MediaSource.Kind>()
        sources = (saved?.sources ?? []).filter { kinds.insert($0.kind).inserted }
        selectedID = saved?.selectedID
        if !sources.contains(where: { $0.id == selectedID }) { selectedID = nil }
        reload()
    }

    func addPhotos() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw SourceFailure.permissionDenied }
        add(.photos)
    }

    private func add(_ kind: MediaSource.Kind) {
        guard !contains(kind) else { return }
        let source = MediaSource(id: UUID(), kind: kind)
        sources.append(source)
        if selectedID == nil { selectedID = source.id; reload() }
        persist()
    }

    func importVideos(_ urls: [URL]) async throws {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let directory = localDirectory
        do {
            try await Task.detached(priority: .userInitiated) {
                try DeviceSourceAdapter.importVideos(urls, into: directory)
            }.value
        } catch { throw SourceFailure.importFailed }
        add(.local)
        if selectedSource?.kind == .local { reload() }
    }

    func select(_ id: UUID) {
        guard sources.contains(where: { $0.id == id }) else { return }
        selectedID = id
        persist()
        reload()
    }

    func remove(_ id: UUID) {
        guard !isImporting else { return }
        // Removing a source never deletes original photos or imported files.
        sources.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil; reload() }
        persist()
    }

    func reload() {
        request?.cancel()
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
                self.content = .failed(error as? SourceFailure ?? .unavailable)
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
