import Foundation

struct PlaybackTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
    let isSelected: Bool
}

struct PlaybackVideoDetails: Sendable {
    let fileName: String
    let dimensions: String?
    let byteCount: Int?
    let synopsis: String?
    let sourceName: String
    let technical: [PlaybackDetailField]
    var duration: Double? = nil
}

struct PlaybackDetailField: Sendable {
    let label: String
    let value: String
}

struct PlaybackQueueInfo: Sendable {
    var duration: Double = 0
    var dimensions: String?
    var byteCount: Int?
}

struct PlaybackHistoryEntry: Identifiable, Codable, Sendable {
    let mediaID: MediaID
    let title: String
    let source: MediaSource
    let watchedAt: Date
    let position: Double
    let duration: Double
    var isPlayed: Bool? = nil
    var isCompleted: Bool? = nil
    var hiddenFromHistory: Bool? = nil
    var id: MediaID { mediaID }
    var isFullyWatched: Bool { isPlayed ?? isCompleted ?? false }
    static func resolvePlayed(trakt: Bool? = nil, server: Bool?, local: Bool?) -> Bool {
        trakt ?? server ?? local ?? false
    }
    var item: MediaItem {
        MediaItem(id: mediaID, title: title, resource: nil,
                  embyItemID: source.kind == .emby ? mediaID.localID : nil, duration: duration,
                  isPlayed: isFullyWatched)
    }
}
