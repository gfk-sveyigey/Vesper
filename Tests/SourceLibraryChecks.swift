import Foundation

/// Standalone state regression checks; run with the command in phase-two-validation.md.
@main
struct SourceLibraryChecks {
    @MainActor
    static func main() async throws {
        let suite = "Vesper.SourceLibraryChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = SourceLibrary(defaults: defaults)
        precondition(library.sources.isEmpty && library.selectedID == nil)
        precondition(library.content == .unselected)
        library.addDemo(name: "  ", behavior: .content)
        precondition(library.sources.isEmpty)
        library.addDemo(name: " A ", behavior: .content)
        let first = library.sources[0].id
        precondition(library.sources[0].name == "A" && library.selectedID == first)
        precondition(library.content == .loading)
        try await wait { if case .loaded = library.content { true } else { false } }
        guard case .loaded(let items) = library.content else { preconditionFailure() }
        precondition(items.count == 6 && items.allSatisfy { $0.id.sourceID == first && $0.resource == nil })
        precondition(!library.sources[0].capabilities.contains(.playback))
        library.addDemo(name: "B", behavior: .empty)
        let second = library.sources[1].id
        precondition(library.selectedID == first)
        library.select(second)
        try await wait { library.content == .loaded([]) }
        library.configure(second, behavior: .failure)
        try await wait { library.content == .failed(.unavailable) }
        library.select(first)
        try await wait { if case .loaded(let result) = library.content { result.count == 6 } else { false } }
        library.configure(second, behavior: .offline)
        precondition(library.selectedID == first)
        library.select(second)
        try await wait { library.content == .failed(.offline) }
        let restored = SourceLibrary(defaults: defaults)
        precondition(restored.sources == library.sources && restored.selectedID == second)
        try await wait { restored.content == .failed(.offline) }
        library.remove(first)
        precondition(library.selectedID == second)
        library.remove(second)
        precondition(library.sources.isEmpty && library.selectedID == nil && library.content == .unselected)
        let emptyRestored = SourceLibrary(defaults: defaults)
        precondition(emptyRestored.sources.isEmpty && emptyRestored.selectedID == nil)

        // Adapter deliberately ignores cancellation: generation guard must still
        // reject the old source's late completion.
        let race = SourceLibrary(defaults: defaults, adapter: UncooperativeAdapter())
        race.addDemo(name: "slow", behavior: .failure)
        let slow = race.sources[0].id
        race.addDemo(name: "fast", behavior: .content)
        let fast = race.sources[1].id
        race.select(fast)
        try await wait { if case .loaded = race.content { true } else { false } }
        try await Task.sleep(for: .milliseconds(350))
        guard case .loaded(let current) = race.content else { preconditionFailure("Old request replaced current result") }
        precondition(current.first?.id.sourceID == fast && race.selectedID != slow)
        race.select(UUID())
        precondition(race.selectedID == fast)
        print("SourceLibrary checks passed: selection, persistence, failure isolation, removal and stale-result rejection.")
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

private struct UncooperativeAdapter: SourceAdapter {
    func media(in source: MediaSource) async throws -> [MediaItem] {
        await Task.detached {
            try? await Task.sleep(for: .milliseconds(source.behavior == .failure ? 200 : 20))
        }.value
        if source.behavior == .failure { throw SourceFailure.unavailable }
        return [MediaItem(id: MediaID(sourceID: source.id, localID: "test"), title: "Test", resource: nil)]
    }
}
