import Foundation

@MainActor
protocol PlaybackRecordService {
    func update(_ change: EmbyPlaybackRecordChange, for item: MediaItem,
                source: MediaSource) async throws
    func clearTraktProgress(for item: MediaItem, source: MediaSource) async throws
}

@MainActor
struct EmbyTraktPlaybackRecordService: PlaybackRecordService {
    private let repository: EmbyRepository
    private let trakt: TraktAccountStore

    init(repository: EmbyRepository = .shared, trakt: TraktAccountStore = .shared) {
        self.repository = repository
        self.trakt = trakt
    }

    func update(_ change: EmbyPlaybackRecordChange, for item: MediaItem,
                source: MediaSource) async throws {
        try await repository.updatePlaybackRecord(for: item, source: source, change: change)
    }

    func clearTraktProgress(for item: MediaItem, source: MediaSource) async throws {
        guard source.kind == .emby, trakt.isConnected else { return }
        try await trakt.clearPlaybackProgress(for: item, source: source)
    }
}

/// Owns ordering and remote-service coordination for per-item playback record
/// mutations. PlaybackSession remains responsible for optimistic UI state.
@MainActor
final class PlaybackRecordCoordinator {
    private struct PendingWrite {
        let id: UUID
        let task: Task<Void, Error>
    }

    private let service: any PlaybackRecordService
    private var writes: [MediaID: PendingWrite] = [:]

    init(service: any PlaybackRecordService = EmbyTraktPlaybackRecordService()) {
        self.service = service
    }

    /// Serialize writes for the same item while allowing unrelated items to
    /// update independently. This keeps remote ordering out of UI state code.
    func enqueue(_ change: EmbyPlaybackRecordChange, for item: MediaItem,
                 source: MediaSource, log: @escaping @MainActor @Sendable (String) -> Void) -> Task<Void, Error> {
        let previous = writes[item.id]?.task
        let writeID = UUID()
        let service = self.service
        let task = Task { [weak self] in
            if let previous { _ = await previous.result }
            defer {
                if let self, self.writes[item.id]?.id == writeID {
                    self.writes.removeValue(forKey: item.id)
                }
            }
            do {
                try await service.update(change, for: item, source: source)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let operation: String
                switch change {
                case .clearProgress: operation = "清除播放进度"
                case .setPlayed: operation = "更新观看标记"
                case .setFavorite: operation = "更新收藏状态"
                }
                let failure = EmbyOperationFailure(operation: operation, itemID: item.id.localID,
                                                   sourceID: source.id, reason: error.localizedDescription)
                log("Emby action source=\(source.id) item=\(item.id.localID) operation=\(operation): \(error.localizedDescription)")
                throw failure
            }
        }
        writes[item.id] = PendingWrite(id: writeID, task: task)
        return task
    }

    func clearTraktProgress(for item: MediaItem, source: MediaSource) async throws {
        try await service.clearTraktProgress(for: item, source: source)
    }
}
