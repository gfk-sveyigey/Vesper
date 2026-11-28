import Foundation
import PlaybackContracts

/// The same owner survives presentation changes (full-screen, mini player, PiP).
/// Reports and cleanup are serialized and scoped to exactly one server session.
@MainActor
final class EmbyPlaybackSession: PlaybackTranscodingProvider {
    let source: MediaSource
    let item: MediaItem
    let mediaSourceID: String
    private(set) var playSessionID: String
    private var reportChain: Task<Void, Never>?
    private var lastReport = Date.distantPast
    private var started = false
    private var stopped = false
    private var lastPosition: Double = 0
    private var lastPaused = true
    private var lastRate: Float = 1
    private var playMethod = "DirectPlay"
    private var remembersProgress = true
    private var transcodeSessionIDs: Set<String> = []
    private var pendingTranscodeID: String?
    private let repository: any MediaSourcePlaybackReportingService

    init(source: MediaSource, item: MediaItem, playSessionID: String, mediaSourceID: String,
         repository: any MediaSourcePlaybackReportingService = MediaSourceServices.reporting) {
        self.source = source; self.item = item; self.playSessionID = playSessionID
        self.mediaSourceID = mediaSourceID
        self.repository = repository
    }

    func update(position: Double, paused: Bool, rate: Float, remembersProgress: Bool, ready: Bool) {
        guard !stopped, position.isFinite, ready else { return }
        let changed = lastPaused != paused || lastRate != rate
        lastPosition = position; lastPaused = paused; lastRate = rate
        self.remembersProgress = remembersProgress
        if !started {
            started = true
            enqueue(action: "playing")
        } else if changed || Date().timeIntervalSince(lastReport) >= 10 {
            enqueue(action: "progress")
        }
    }

    private func enqueue(action: String) {
        let previous = reportChain
        let source = self.source, itemID = item.id.localID, sessionID = playSessionID
        let paused = lastPaused, method = playMethod
        let position = lastPosition
        let remembersProgress = self.remembersProgress
        let mediaSourceID = self.mediaSourceID
        let repository = self.repository
        lastReport = Date()
        reportChain = Task {
            await previous?.value
            await repository.report(source: source, itemID: itemID, playSessionID: sessionID,
                                                position: position, mediaSourceID: mediaSourceID,
                                                paused: paused, action: action, playMethod: method,
                                                includePosition: remembersProgress)
        }
    }

    func didSeek(to position: Double, paused: Bool) {
        guard !stopped, position.isFinite else { return }
        lastPosition = position; lastPaused = paused
        if started { enqueue(action: "progress") }
    }

    @discardableResult func finish(reportStop: Bool = true) -> Task<Void, Never>? {
        guard !stopped else { return reportChain }
        stopped = true
        if started, reportStop { enqueue(action: "stopped") }
        let previous = reportChain
        let source = self.source, ids = transcodeSessionIDs.union([playSessionID])
        let repository = self.repository
        reportChain = Task {
            await previous?.value
            for id in ids { await repository.stopTranscoding(source: source, playSessionID: id) }
        }
        return reportChain
    }

    func transcode(position: Double, forceVideoTranscode: Bool = false) async throws -> TranscodedPlaybackResource {
        guard !stopped else { throw CancellationError() }
        if let failedID = pendingTranscodeID {
            await repository.stopTranscoding(source: source, playSessionID: failedID)
            transcodeSessionIDs.remove(failedID)
            pendingTranscodeID = nil
        }
        let result = try await repository.transcodedResource(item: item, source: source, position: position,
                                                              forceVideoTranscode: forceVideoTranscode)
        guard !stopped else {
            await repository.stopTranscoding(source: source, playSessionID: result.sessionID)
            throw CancellationError()
        }
        transcodeSessionIDs.insert(result.sessionID)
        pendingTranscodeID = result.sessionID
        return result.resource
    }

    func didActivateTranscoding() {
        guard let newID = pendingTranscodeID else { return }
        pendingTranscodeID = nil
        let oldID = playSessionID
        if started { enqueue(action: "stopped") }
        playSessionID = newID
        playMethod = "Transcode"
        started = false
        let previous = reportChain
        let source = self.source
        let repository = self.repository
        reportChain = Task {
            await previous?.value
            if oldID != newID { await repository.stopTranscoding(source: source, playSessionID: oldID) }
        }
        transcodeSessionIDs.remove(oldID)
    }

    func stopTranscoding() async {
        // PlaybackSession.finish owns the ordered report-then-cleanup sequence.
        // Core shutdown alone can be an engine retry, not a playback stop.
    }
}
