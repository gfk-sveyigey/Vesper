import Foundation

/// Run on macOS with LocalFileStore.swift; uses only disposable test directories.
@main
struct LocalFileStoreChecks {
    static func main() async throws {
        let manager = FileManager.default
        let sandbox = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = sandbox.appendingPathComponent("Library")
        let outside = sandbox.appendingPathComponent("Outside")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: sandbox) }
        let store = LocalFileStore()
        let payload = Data("original video bytes".utf8)
        try payload.write(to: root.appendingPathComponent("clip.mov"))
        try await store.createFolder(root: root, directory: "", name: "Folder")
        try await store.createFolder(root: root, directory: "Folder", name: "Child")
        let entries = try await store.entries(root: root, directory: "")
        precondition(entries.first?.name == "Folder")
        let clip = entries.first { $0.name == "clip.mov" }!
        precondition(clip.dateAdded != nil)
        try await store.rename(root: root, entry: clip, name: "renamed.mov")
        let renamed = LocalFileEntry(path: "renamed.mov", name: "renamed.mov", isDirectory: false)
        try await store.move(root: root, entry: renamed, directory: "Folder")
        let movedPayload = try Data(contentsOf: root.appendingPathComponent("Folder/renamed.mov"))
        precondition(movedPayload == payload)
        try payload.write(to: root.appendingPathComponent("duplicate.mov"))
        let duplicate = LocalFileEntry(path: "duplicate.mov", name: "duplicate.mov", isDirectory: false)
        try await expectFailure { try await store.rename(root: root, entry: duplicate, name: "Folder") }
        try await expectFailure { try await store.createFolder(root: root, directory: "", name: "../escape") }
        try await expectFailure { try await store.createFolder(root: root, directory: "../Outside", name: "escape") }
        let folder = LocalFileEntry(path: "Folder", name: "Folder", isDirectory: true)
        try await expectFailure { try await store.move(root: root, entry: folder, directory: "Folder/Child") }
        try manager.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: outside)
        try await expectFailure { try await store.createFolder(root: root, directory: "Link", name: "escape") }
        let nestedMatches = try await store.matchingFiles(root: root, query: "  RENAMED  ")
        precondition(nestedMatches.map(\.path) == ["Folder/renamed.mov"])
        let blankMatches = try await store.matchingFiles(root: root, query: "  ")
        precondition(blankMatches.isEmpty)
        try payload.write(to: outside.appendingPathComponent("renamed-outside.mov"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("renamed-link.mov"),
                                       withDestinationURL: outside.appendingPathComponent("renamed-outside.mov"))
        let confinedMatches = try await store.matchingFiles(root: root, query: "renamed")
        precondition(confinedMatches.map(\.path) == ["Folder/renamed.mov"])
        try manager.removeItem(at: outside.appendingPathComponent("renamed-outside.mov"))
        let forgedRoot = LocalFileEntry(path: "", name: "", isDirectory: true)
        try await expectFailure { try await store.delete(root: root, entry: forgedRoot) }
        let outsideContents = try manager.contentsOfDirectory(atPath: outside.path)
        precondition(outsideContents.isEmpty)
        precondition(manager.fileExists(atPath: root.appendingPathComponent("duplicate.mov").path))
        try await store.delete(root: root, entry: folder)
        precondition(!manager.fileExists(atPath: root.appendingPathComponent("Folder").path))
        print("Local file operations and source containment checks passed.")
    }

    static func expectFailure(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch { return }
        preconditionFailure("An invalid filesystem operation succeeded")
    }
}
