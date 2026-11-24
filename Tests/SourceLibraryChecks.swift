import Foundation

/// Standalone state regression checks for source loading and persistence.
@main
struct SourceLibraryChecks {
    @MainActor
    static func main() async throws {
        let suite = "Vesper.SourceLibraryChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = SourceLibrary(defaults: defaults, adapter: TestDeviceAdapter())
        precondition(library.sources.isEmpty && library.selectedID == nil)
        precondition(library.content == .unselected)

        // Device sources are unique by kind and bookmarks survive persistence.
        library.addDeviceSource(kind: .local, name: "Local", bookmark: Data([1, 2, 3]))
        library.addDeviceSource(kind: .local, name: "Duplicate", bookmark: Data([4]))
        precondition(library.sources.count == 1)
        precondition(library.sources[0].folderBookmark == Data([1, 2, 3]))
        let deviceRestored = SourceLibrary(defaults: defaults)
        precondition(deviceRestored.sources == library.sources)
        library.remove(library.sources[0].id)

        // Registering imported files creates one Documents-backed local source.
        // It also replaces a legacy folder bookmark without changing selection.
        library.registerImportedVideos(name: "Local")
        let imported = library.sources[0]
        precondition(library.sources.count == 1 && imported.kind == .local)
        precondition(imported.folderBookmark == nil && library.selectedID == nil)
        library.registerImportedVideos(name: "Local")
        precondition(library.sources.count == 1 && library.sources[0].id == imported.id && library.selectedID == nil)
        library.remove(imported.id)
        library.addDeviceSource(kind: .local, name: "Legacy", bookmark: Data([1]))
        let legacyID = library.selectedID
        library.registerImportedVideos(name: "Local")
        precondition(library.selectedID == legacyID && library.sources.count == 1)
        precondition(library.selectedSource?.folderBookmark == nil)
        let importedRestored = SourceLibrary(defaults: defaults)
        precondition(importedRestored.sources == library.sources && importedRestored.selectedID == legacyID)
        library.remove(legacyID!)

        // Adapter deliberately ignores cancellation: generation guard must still
        // reject the old source's late completion.
        let race = SourceLibrary(defaults: defaults, adapter: TestDeviceAdapter())
        race.addDeviceSource(kind: .local, name: "Slow")
        let slow = race.sources[0].id
        race.addDeviceSource(kind: .photos, name: "Fast")
        let fast = race.sources[1].id
        race.select(fast)
        try await wait { if case .loaded = race.content { true } else { false } }
        try await Task.sleep(for: .milliseconds(350))
        guard case .loaded(let current) = race.content else { preconditionFailure("Old request replaced current result") }
        precondition(current.first?.id.sourceID == fast && race.selectedID != slow)
        race.select(UUID())
        precondition(race.selectedID == fast)
        print("SourceLibrary checks passed: device source persistence, import registration and stale-result rejection.")
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

private struct TestDeviceAdapter: SourceAdapter {
    func media(in source: MediaSource) async throws -> [MediaItem] {
        await Task.detached {
            try? await Task.sleep(for: .milliseconds(source.kind == .local ? 200 : 20))
        }.value
        if source.kind == .local { throw SourceFailure.unavailable }
        return [MediaItem(id: MediaID(sourceID: source.id, localID: "test"), title: "Test", resource: nil)]
    }
}
