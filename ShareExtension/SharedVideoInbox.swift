import Foundation

enum SharedVideoInbox {
    static let root: URL? = {
        #if os(iOS)
        let current = Bundle.main
        let app: Bundle
        let share: Bundle
        if current.bundleURL.pathExtension == "appex" {
            let plugins = current.bundleURL.deletingLastPathComponent()
            guard plugins.lastPathComponent == "PlugIns",
                  let host = Bundle(url: plugins.deletingLastPathComponent()) else { return nil }
            app = host
            share = current
        } else {
            guard let extensionBundle = Bundle(url: current.bundleURL
                .appendingPathComponent("PlugIns/VesperShare.appex", isDirectory: true)) else { return nil }
            app = current
            share = extensionBundle
        }

        let key = "VesperAppGroupIdentifier"
        if let configured = app.object(forInfoDictionaryKey: key) as? String, !configured.isEmpty,
           configured == (share.object(forInfoDictionaryKey: key) as? String) {
            return inboxURL(for: configured)
        }

        let appGroups = signedGroups(for: app)
        let extensionGroups = signedGroups(for: share)
        guard let group = preferredCommonGroup(appGroups, extensionGroups) else { return nil }
        return inboxURL(for: group)
        #else
        return nil
        #endif
    }()

    #if os(iOS)
    private static func inboxURL(for identifier: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)?
            .appendingPathComponent("VesperVideoInbox", isDirectory: true)
    }

    private static func signedGroups(for bundle: Bundle) -> Set<String> {
        guard let url = bundle.executableURL,
              let bytes = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
        return signedGroups(in: bytes)
    }
    #endif

    static func preferredCommonGroup(_ appGroups: Set<String>, _ extensionGroups: Set<String>) -> String? {
        // Both processes must choose the same group before checking container access.
        appGroups.intersection(extensionGroups).min()
    }

    /// Read the XML entitlement slot of a thin, little-endian 64-bit Mach-O.
    static func signedGroups(in executable: Data) -> Set<String> {
        guard word(executable, at: 0) == 0xfeedfacf,
              let commandBytes = word(executable, at: 20),
              executable.count >= 32 + commandBytes else { return [] }
        let commandsEnd = 32 + commandBytes
        var offset = 32
        while offset <= commandsEnd - 8 {
            guard let command = word(executable, at: offset),
                  let size = word(executable, at: offset + 4),
                  size >= 8, size <= commandsEnd - offset else { return [] }
            if command == 0x1d { // LC_CODE_SIGNATURE
                guard size >= 16, let start = word(executable, at: offset + 8),
                      let length = word(executable, at: offset + 12),
                      start >= commandsEnd, start <= executable.count,
                      length <= executable.count - start else { return [] }
                return groups(inSignature: executable.subdata(in: start..<(start + length)))
            }
            offset += size
        }
        return []
    }

    private static func groups(inSignature signature: Data) -> Set<String> {
        // The embedded signature and its blob index use big-endian integers.
        guard word(signature, at: 0, bigEndian: true) == 0xfade0cc0,
              let length = word(signature, at: 4, bigEndian: true),
              length >= 12, length <= signature.count,
              let count = word(signature, at: 8, bigEndian: true),
              count <= (length - 12) / 8 else { return [] }
        for index in 0..<count {
            let entry = 12 + index * 8
            guard word(signature, at: entry, bigEndian: true) == 5 else { continue }
            guard let start = word(signature, at: entry + 4, bigEndian: true),
                  start >= 12 + count * 8, start <= length - 8,
                  word(signature, at: start, bigEndian: true) == 0xfade7171,
                  let blobLength = word(signature, at: start + 4, bigEndian: true),
                  blobLength >= 8, blobLength <= length - start else { return [] }
            let payload = signature.subdata(in: (start + 8)..<(start + blobLength))
            guard let plist = try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil),
                  let entitlements = plist as? [String: Any],
                  let groups = entitlements["com.apple.security.application-groups"] as? [String] else { return [] }
            return Set(groups.filter { $0.hasPrefix("group.") && $0.count > 6 })
        }
        return []
    }

    private static func word(_ data: Data, at offset: Int, bigEndian: Bool = false) -> Int? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return data.withUnsafeBytes { bytes in
            let value = bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            return Int(bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value))
        }
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
