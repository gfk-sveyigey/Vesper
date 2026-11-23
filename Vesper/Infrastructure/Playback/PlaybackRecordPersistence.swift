import Foundation

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
        guard let separator = storageKey.firstIndex(of ":"),
              let sourceID = UUID(uuidString: String(storageKey[..<separator])) else { return nil }
        return MediaID(sourceID: sourceID, localID: String(storageKey[storageKey.index(after: separator)...]))
    }
}
