import Foundation
import Combine

/// Stable identity is scoped to a source, not a title or display URL.
struct MediaID: Hashable, Codable, Sendable {
    let sourceID: UUID
    let localID: String
}

struct PlayableResource: Hashable, Sendable {
    let url: URL
}

struct MediaItem: Identifiable, Hashable, Sendable {
    let id: MediaID
    let title: String
    let resource: PlayableResource?
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
    enum Kind: String, Codable { case demo }
    let id: UUID
    var name: String
    let kind: Kind
    var behavior: DemoSourceBehavior
    var capabilities: SourceCapabilities { [.browse] }
}

enum SourceFailure: Error, Equatable {
    case unavailable, offline
}

protocol SourceAdapter: Sendable {
    func media(in source: MediaSource) async throws -> [MediaItem]
}

struct DemoSourceAdapter: SourceAdapter {
    func media(in source: MediaSource) async throws -> [MediaItem] {
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
        persist()
        reload()
    }

    func configure(_ id: UUID, behavior: DemoSourceBehavior) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].behavior = behavior
        persist()
        if selectedID == id { reload() }
    }

    func remove(_ id: UUID) {
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
