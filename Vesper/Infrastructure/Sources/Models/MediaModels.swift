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
    var dateAdded: Date? = nil
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

struct MediaSource: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable { case photos, local, emby }
    let id: UUID
    var name: String
    let kind: Kind
    var folderBookmark: Data? = nil
    var emby: EmbySourceConfiguration? = nil
    var cacheIdentity: String { emby.map { "\($0.serverAddress)|\($0.userID ?? "")|\($0.username)" } ?? folderBookmark?.base64EncodedString() ?? "" }
}

enum SourceFailure: Error, Equatable {
    case unavailable, message(String)
}

protocol SourceAdapter: Sendable {
    func media(in source: MediaSource) async throws -> [MediaItem]
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
