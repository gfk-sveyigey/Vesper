import Foundation

enum SharedVideoInbox {
    static var root: URL? {
        #if os(iOS)
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "VesperAppGroupIdentifier") as? String,
              !identifier.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            return nil
        }
        return container.appendingPathComponent("VesperVideoInbox", isDirectory: true)
        #else
        return nil
        #endif
    }

    static func stagingDirectory(in root: URL, id: UUID) -> URL {
        root.appendingPathComponent("." + id.uuidString, isDirectory: true)
    }

    static func publish(_ staging: URL, in root: URL, id: UUID) throws {
        try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    static func batches(in root: URL) -> [URL] {
        directories(in: root)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return first == second ? $0.lastPathComponent < $1.lastPathComponent : first < second
            }
    }

    static func files(in batch: URL) -> [URL] {
        directories(in: batch)
            .filter { Int($0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { item in
                let files = try? FileManager.default.contentsOfDirectory(at: item,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                return files?.first { url in
                    guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                    return values.isRegularFile == true && values.isSymbolicLink != true
                }
            }
    }

    private static func directories(in parent: URL) -> [URL] {
        let directories = try? FileManager.default.contentsOfDirectory(at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        return (directories ?? []).filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }
}
