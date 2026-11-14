import Foundation

/// Run on macOS with the command in docs/phase-two-validation.md.
@main
struct SourceLibraryChecks {
    @MainActor
    static func main() async throws {
        let suite = "Vesper.SourceLibraryChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let videos = root.appendingPathComponent("Library")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(Data([0]), forKey: "sources.snapshot.v1")
        let library = SourceLibrary(defaults: defaults, localDirectory: videos)
        precondition(defaults.object(forKey: "sources.snapshot.v1") == nil)
        precondition(library.sources.isEmpty && library.content == .unselected)
        // Small fixtures verify file ownership/rollback, not video decoding.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("video.mp4")
        try Data([0, 1, 2]).write(to: original)
        try await library.importVideos([original])
        precondition(library.sources.count == 1 && library.contains(.local))
        let id = library.sources[0].id
        try await wait {
            if case .loaded(let items) = library.content { items.count == 1 } else { false }
        }
        guard case .loaded(let items) = library.content,
              case .file(let imported) = items[0].resource else { preconditionFailure() }
        precondition(imported != original && items[0].id.sourceID == id)
        let copiedData = try Data(contentsOf: imported)
        let originalData = try Data(contentsOf: original)
        precondition(copiedData == originalData)
        let restored = SourceLibrary(defaults: defaults, localDirectory: videos)
        precondition(restored.sources == library.sources && restored.selectedID == id)
        try await wait { restored.content == library.content }

        let invalid = root.appendingPathComponent("missing.mp4")
        do {
            try await library.importVideos([original, invalid])
            preconditionFailure("Missing input must fail")
        } catch { precondition(error as? SourceFailure == .importFailed) }
        library.reload()
        try await wait { library.content == .loaded(items) }
        library.select(UUID())
        precondition(library.selectedID == id)
        library.remove(id)
        precondition(library.content == .unselected && library.sources.isEmpty)
        precondition(FileManager.default.fileExists(atPath: original.path))
        precondition(FileManager.default.fileExists(atPath: imported.path))
        try await library.importVideos([original])
        try await wait {
            if case .loaded(let result) = library.content { result.count == 1 } else { false }
        }

        let raceDefaults = UserDefaults(suiteName: suite + ".race")!
        defer { raceDefaults.removePersistentDomain(forName: suite + ".race") }
        let race = SourceLibrary(defaults: raceDefaults, adapter: UncooperativeAdapter(), localDirectory: videos)
        try await race.importVideos([original])
        try await Task.sleep(for: .milliseconds(30))
        race.reload()
        try await wait { race.content == .loaded([]) }
        try await Task.sleep(for: .milliseconds(300))
        precondition(race.content == .loaded([]), "Old failure replaced the new result")
        print("Source checks passed: uniqueness, import, rollback, persistence, removal and stale-result rejection.")
    }

    @MainActor
    private static func wait(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out waiting for source state")
    }
}

private actor UncooperativeAdapter: SourceAdapter {
    private var requests = 0
    func media(in source: MediaSource) async throws -> [MediaItem] {
        requests += 1
        let first = requests == 1
        await Task.detached { try? await Task.sleep(for: .milliseconds(first ? 200 : 20)) }.value
        if first { throw SourceFailure.unavailable }
        return []
    }
}
