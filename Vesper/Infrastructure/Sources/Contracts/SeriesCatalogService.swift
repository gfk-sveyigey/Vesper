import Foundation

protocol SeriesMediaCatalogService: Sendable {
    func detailMetadata(for item: MediaItem, source: MediaSource) async throws -> EmbyDetailMetadata
    func seriesSeasonCount(for series: MediaItem, source: MediaSource) async throws -> Int
    func seriesEpisodes(for series: MediaItem, source: MediaSource, limit: Int?) async throws -> [EmbyEpisode]
    func similarTitles(for item: MediaItem, source: MediaSource) async throws -> [MediaItem]
    func details(for item: MediaItem, source: MediaSource) async throws -> EmbyItemDetails
    func screenshotData(for item: MediaItem, source: MediaSource) async -> [Data]
}
