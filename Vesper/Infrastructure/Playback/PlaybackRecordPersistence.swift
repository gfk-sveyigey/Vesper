import Foundation
import Combine

/// Persistence boundary for playback history, watched-state overrides and
/// resume progress. Policy decisions remain with the playback domain owner.
@MainActor
final class PlaybackRecordPersistence {
    private let defaults: UserDefaults

    private let historyKey = "player.history.v1"
    private let progressKey = "player.savedProgress"
    private let durationKey = "player.savedDurations"
    private let localPlayedKey = "player.localPlayedStates.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadHistory() -> [PlaybackHistoryEntry] {
        guard let data = defaults.data(forKey: historyKey),
              let entries = try? JSONDecoder().decode([PlaybackHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    func loadLocalPlayedStates() -> [String: Bool] {
        defaults.dictionary(forKey: localPlayedKey) as? [String: Bool] ?? [:]
    }

    func saveHistory(_ entries: [PlaybackHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: historyKey)
    }

    func saveLocalPlayedStates(_ states: [String: Bool]) {
        defaults.set(states, forKey: localPlayedKey)
    }

    func saveProgress(for id: MediaID, position: Double, duration: Double) {
        let key = Self.storageKey(for: id)
        var positions = defaults.dictionary(forKey: progressKey) as? [String: Double] ?? [:]
        var durations = defaults.dictionary(forKey: durationKey) as? [String: Double] ?? [:]
        if position >= duration - min(2, duration * 0.05) || position <= 0 {
            positions.removeValue(forKey: key)
            durations.removeValue(forKey: key)
        } else {
            positions[key] = max(0, position)
            durations[key] = duration
        }
        defaults.set(positions, forKey: progressKey)
        defaults.set(durations, forKey: durationKey)
    }

    func savedProgress(for id: MediaID) -> Double {
        let value = defaults.dictionary(forKey: progressKey)?[Self.storageKey(for: id)] as? Double ?? 0
        return value.isFinite ? max(0, value) : 0
    }

    func savedDuration(for id: MediaID) -> Double {
        let value = defaults.dictionary(forKey: durationKey)?[Self.storageKey(for: id)] as? Double ?? 0
        return value.isFinite ? max(0, value) : 0
    }

    func clearAllProgress() {
        defaults.removeObject(forKey: progressKey)
        defaults.removeObject(forKey: durationKey)
    }

    func clearProgress(for id: MediaID) {
        let key = Self.storageKey(for: id)
        var positions = defaults.dictionary(forKey: progressKey) as? [String: Double] ?? [:]
        var durations = defaults.dictionary(forKey: durationKey) as? [String: Double] ?? [:]
        positions.removeValue(forKey: key)
        durations.removeValue(forKey: key)
        defaults.set(positions, forKey: progressKey)
        defaults.set(durations, forKey: durationKey)
    }

    func removePlaybackData(matching matches: (MediaID) -> Bool) {
        for key in [progressKey, durationKey] {
            var values = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
            values = values.filter { storageKey, _ in
                guard let id = Self.mediaID(from: storageKey) else { return true }
                return !matches(id)
            }
            defaults.set(values, forKey: key)
        }
    }

    static func storageKey(for id: MediaID) -> String {
        id.sourceID.uuidString + ":" + id.localID
    }

    static func mediaID(from storageKey: String) -> MediaID? {
        guard let separator = storageKey.firstIndex(of: ":"),
              let sourceID = UUID(uuidString: String(storageKey[..<separator])) else { return nil }
        return MediaID(sourceID: sourceID, localID: String(storageKey[storageKey.index(after: separator)...]))
    }
}

/// Owns the observable playback-record state and its local persistence.
/// PlaybackSession coordinates playback timing, while record policy and storage
/// remain isolated here so they can be exercised independently.
@MainActor
final class PlaybackRecordStore: ObservableObject {
    struct PlayedEdit {
        let id: UUID
        let played: Bool
        var syncedAt: Date?
    }

    @Published private(set) var history: [PlaybackHistoryEntry]
    @Published private(set) var playedEdits: [MediaID: PlayedEdit] = [:]
    @Published private(set) var traktEpisodeStates: [MediaID: TraktEpisodePlaybackState] = [:]
    @Published private(set) var revision = 0

    private var localPlayedStates: [String: Bool]
    private let persistence: PlaybackRecordPersistence

    init(persistence: PlaybackRecordPersistence = PlaybackRecordPersistence()) {
        self.persistence = persistence
        let history = persistence.loadHistory()
        var local = persistence.loadLocalPlayedStates()
        for entry in history where entry.source.kind != .emby {
            let key = PlaybackRecordPersistence.storageKey(for: entry.mediaID)
            if local[key] == nil { local[key] = entry.isFullyWatched }
        }
        self.history = history
        self.localPlayedStates = local
        persistence.saveLocalPlayedStates(local)
    }

    func entry(for id: MediaID) -> PlaybackHistoryEntry? {
        history.first { $0.mediaID == id }
    }

    func localPlayed(for id: MediaID) -> Bool? {
        localPlayedStates[PlaybackRecordPersistence.storageKey(for: id)]
    }

    func setLocalPlayed(_ played: Bool?, for id: MediaID) {
        let key = PlaybackRecordPersistence.storageKey(for: id)
        localPlayedStates[key] = played
        persistence.saveLocalPlayedStates(localPlayedStates)
        changed()
    }

    func containsLocalPlayed(_ id: MediaID) -> Bool {
        localPlayedStates[PlaybackRecordPersistence.storageKey(for: id)] != nil
    }

    func removeLocalPlayed(matching matches: (MediaID) -> Bool) {
        for key in Array(localPlayedStates.keys) {
            guard let id = PlaybackRecordPersistence.mediaID(from: key) else { continue }
            if matches(id) { localPlayedStates.removeValue(forKey: key) }
        }
        persistence.saveLocalPlayedStates(localPlayedStates)
    }

    func edit(for id: MediaID) -> PlayedEdit? { playedEdits[id] }

    func traktState(for id: MediaID) -> TraktEpisodePlaybackState? { traktEpisodeStates[id] }

    func applyTraktStates(_ states: [MediaID: TraktEpisodePlaybackState], replacing ids: Set<MediaID>) {
        traktEpisodeStates = traktEpisodeStates.filter { !ids.contains($0.key) }
        for (id, state) in states { traktEpisodeStates[id] = state }
        for id in ids where playedEdits[id]?.syncedAt != nil { playedEdits[id] = nil }
        changed()
    }

    func updateTraktState(for id: MediaID, _ update: (inout TraktEpisodePlaybackState) -> Void) {
        guard var state = traktEpisodeStates[id] else { return }
        update(&state)
        traktEpisodeStates[id] = state
        changed()
    }

    func setTraktState(_ state: TraktEpisodePlaybackState?, for id: MediaID) {
        traktEpisodeStates[id] = state
        changed()
    }

    func setEdit(_ edit: PlayedEdit?, for id: MediaID) {
        playedEdits[id] = edit
        changed()
    }

    func markEditSynced(_ id: MediaID, editID: UUID, at date: Date = Date()) {
        guard var edit = playedEdits[id], edit.id == editID else { return }
        edit.syncedAt = date
        playedEdits[id] = edit
        changed()
    }

    func record(_ entry: PlaybackHistoryEntry, played: Bool, persistLocalMarker: Bool) {
        history.removeAll { $0.mediaID == entry.mediaID }
        history.insert(entry, at: 0)
        if history.count > 1000 { history.removeLast(history.count - 1000) }
        updateTraktState(for: entry.mediaID) { $0.isPlayed = played }
        if persistLocalMarker {
            localPlayedStates[PlaybackRecordPersistence.storageKey(for: entry.mediaID)] = played
            persistence.saveLocalPlayedStates(localPlayedStates)
        }
        persistence.saveHistory(history)
        changed()
    }

    func restore(entry: PlaybackHistoryEntry?, edit: PlayedEdit?, for id: MediaID) {
        history.removeAll { $0.mediaID == id }
        if let entry { history.insert(entry, at: 0) }
        playedEdits[id] = edit
        persistence.saveHistory(history)
        changed()
    }

    func replaceHistory(_ entries: [PlaybackHistoryEntry]) {
        history = entries
        persistence.saveHistory(entries)
        changed()
    }

    func saveProgress(for id: MediaID, position: Double, duration: Double) {
        persistence.saveProgress(for: id, position: position, duration: duration)
        changed()
    }

    func savedProgress(for id: MediaID) -> Double { persistence.savedProgress(for: id) }

    func savedDuration(for id: MediaID) -> Double { persistence.savedDuration(for: id) }

    func clearProgress(for id: MediaID) {
        persistence.clearProgress(for: id)
        changed()
    }

    func clearAllProgress() {
        persistence.clearAllProgress()
        changed()
    }

    func remove(matching matches: (MediaID) -> Bool) {
        history.removeAll { matches($0.mediaID) }
        for key in Array(localPlayedStates.keys) {
            guard let id = PlaybackRecordPersistence.mediaID(from: key) else { continue }
            if matches(id) { localPlayedStates.removeValue(forKey: key) }
        }
        traktEpisodeStates = traktEpisodeStates.filter { !matches($0.key) }
        playedEdits = playedEdits.filter { !matches($0.key) }
        persistence.saveLocalPlayedStates(localPlayedStates)
        persistence.removePlaybackData(matching: matches)
        persistence.saveHistory(history)
        changed()
    }

    func removeHistoryEntry(for id: MediaID, removing: Bool) {
        guard let index = history.firstIndex(where: { $0.mediaID == id }) else { return }
        let entry = history[index]
        if entry.source.kind != .emby {
            localPlayedStates[PlaybackRecordPersistence.storageKey(for: id)] = entry.isFullyWatched
            persistence.saveLocalPlayedStates(localPlayedStates)
        }
        if removing { history.remove(at: index) }
        else {
            history[index] = PlaybackHistoryEntry(mediaID: entry.mediaID, title: entry.title,
                                                  source: entry.source, watchedAt: entry.watchedAt,
                                                  position: 0, duration: entry.duration,
                                                  isPlayed: entry.isFullyWatched,
                                                  hiddenFromHistory: entry.hiddenFromHistory)
        }
        persistence.saveHistory(history)
        changed()
    }

    private func changed() { revision += 1 }
}
