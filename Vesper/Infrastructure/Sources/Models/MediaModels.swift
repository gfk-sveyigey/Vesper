import Foundation

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
    static let search = Self(rawValue: 1 << 2)
    static let serverCatalog = Self(rawValue: 1 << 3)
    static let playbackRecords = Self(rawValue: 1 << 4)
    static let alternateRoutes = Self(rawValue: 1 << 5)
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
    var cacheIdentity: String { emby.map { "\($0.serverAddress)|\($0.userID ?? "")|\($0.username)" } ?? folderBookmark?.base64EncodedString() ?? "" }
    var capabilities: SourceCapabilities {
        switch kind {
        case .demo: [.browse]
        case .photos, .local: [.browse, .playback]
        case .emby: [.browse, .playback, .search, .serverCatalog, .playbackRecords, .alternateRoutes]
        }
    }
}

enum SourceFailure: Error, Equatable {
    case unavailable, offline, message(String)
}

protocol SourceAdapter: Sendable {
    func media(in source: MediaSource) async throws -> [MediaItem]
}

protocol MediaSourceAdapter: SourceAdapter {
    var capabilities: SourceCapabilities { get }
    func playbackResource(for item: MediaItem, in source: MediaSource) async throws -> PlayableResource
}


enum MediaSourceCacheIdentity {
    static func scope(for source: MediaSource) -> String {
        "\(source.id)|\(source.kind.rawValue)|\(source.cacheIdentity)"
    }

    static func artworkKey(for item: MediaItem, source: MediaSource) -> String {
        let key = "artwork|\(scope(for: source))|\(item.id.localID)|\(item.imageURL?.absoluteString ?? "")"
        if item.embyItemType == "Episode" {
            return "episode-preview|\(key)|\(item.previewImageURL?.absoluteString ?? "")"
        }
        return item.fallbackImageURL.map { "\(key)|\($0.absoluteString)" } ?? key
    }

}
