import Foundation

enum MediaBrowseScope: Equatable, Sendable {
    case children, titles, episodes, favorites
    case person(EmbyPerson)

    var cacheKey: String {
        switch self {
        case .children: "children"
        case .titles: "titles"
        case .episodes: "episodes"
        case .favorites: "favorites"
        case .person(let person): person.id.map { "person:id:\($0)" } ?? "person:name:\(person.name)"
        }
    }

    var itemTypes: [String]? {
        switch self {
        case .children: nil
        case .titles, .person: ["Movie", "Series", "Video", "MusicVideo", "Trailer"]
        case .favorites: ["Movie", "Series", "Episode", "Video", "MusicVideo", "Trailer"]
        case .episodes: ["Episode"]
        }
    }
}

enum PlaybackRecordChange: Sendable {
    case clearProgress
    case setPlayed(Bool)
    case setFavorite(Bool)
}

struct MediaSearchPage: Sendable {
    let items: [MediaItem]
    let nextIndex: Int
    let hasMore: Bool
}

struct MediaSourceSummary: Sendable {
    let movieCount: Int
    let seriesCount: Int
    let lastPlayed: Date?
}

typealias EmbyBrowseScope = MediaBrowseScope
typealias EmbyPlaybackRecordChange = PlaybackRecordChange
typealias EmbySearchPage = MediaSearchPage
typealias EmbySourceSummary = MediaSourceSummary

protocol MediaSourceCatalogService: Sendable {
    func rootItems(for source: MediaSource) async throws -> [MediaItem]
    func search(for source: MediaSource, query: String, startIndex: Int, limit: Int) async throws -> MediaSearchPage
    func mediaLibraries(for source: MediaSource) async throws -> [MediaItem]
    func latestMedia(for source: MediaSource, libraryID: String) async throws -> [MediaItem]
    func featuredMedia(for source: MediaSource) async throws -> [MediaItem]
    func latestMediaGroup(for source: MediaSource, libraryID: String) async throws -> (items: [MediaItem], totalCount: Int?)
    func sourceSummary(for source: MediaSource) async throws -> MediaSourceSummary
    func items(for source: MediaSource, parentID: String?, startIndex: Int, limit: Int, sortBy: String, sortOrder: String, scope: MediaBrowseScope) async throws -> [MediaItem]
}

extension MediaSourceCatalogService {
    func search(for source: MediaSource, query: String, startIndex: Int = 0) async throws -> MediaSearchPage {
        try await search(for: source, query: query, startIndex: startIndex, limit: 40)
    }
}

protocol MediaSourcePlaybackService: Sendable {
    func playbackResource(item: MediaItem, source: MediaSource, position: Double) async throws -> EmbyPlaybackResource
}
protocol MediaSourcePlaybackReportingService: Sendable {
    func report(source: MediaSource, itemID: String, playSessionID: String, position: Double, mediaSourceID: String, paused: Bool, action: String, playMethod: String, includePosition: Bool) async
    func stopTranscoding(source: MediaSource, playSessionID: String) async
    func transcodedResource(item: MediaItem, source: MediaSource, position: Double, forceVideoTranscode: Bool) async throws -> EmbyTranscodeResult
}
protocol MediaSourceArtworkService: Sendable {
    func artworkData(for item: MediaItem, source: MediaSource, purpose: EmbyArtworkPurpose, orientation: EmbyImageOrientation, allowsRemotePrimary: Bool, prefersLandscapeMovieArtwork: Bool) async -> Data?
    func featuredPosterCandidates(for item: MediaItem, source: MediaSource) async -> [URL]
    func featuredLogoData(for item: MediaItem, source: MediaSource) async -> Data?
}
protocol MediaSourceRecordService: Sendable { func updatePlaybackRecord(for item: MediaItem, source: MediaSource, change: PlaybackRecordChange) async throws }
protocol MediaSourcePlaybackRecordReadService: Sendable {
    func serverName(for source: MediaSource) async throws -> String?
    func clearProgress(for item: MediaItem, source: MediaSource) async throws
}
protocol MediaSourceRouteService: Sendable { func alternateRoutes(for source: MediaSource) async throws -> [EmbyServerRoute] }
protocol MediaSourceIdentityService: Sendable {
    func traktShowIdentity(for show: MediaItem, source: MediaSource) async throws -> TraktMediaIdentity?
    func traktIdentity(for item: MediaItem, source: MediaSource) async throws -> TraktMediaIdentity?
    func skipIdentity(for item: MediaItem, source: MediaSource) async throws -> EmbySkipIdentity?
}
