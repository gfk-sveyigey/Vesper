import Foundation
import CryptoKit

enum AppCacheCategory: String, CaseIterable, Hashable, Sendable {
    case library, images, videos, subtitles, danmaku, shareInbox, other
}

actor AppCacheStore {
    static let shared = AppCacheStore()
    private let directory = URL.cachesDirectory.appending(path: "VesperCache-v1", directoryHint: .isDirectory)
    private var migrated = false
    private var imageGeneration = UUID()
    private(set) var libraryGeneration = UUID()
    private var writes: [AppCacheCategory: Int] = [:]


    nonisolated static func scope(for source: MediaSource) -> String {
        MediaSourceCacheIdentity.scope(for: source)
    }

    nonisolated static func embyArtworkKey(for item: MediaItem, source: MediaSource) -> String {
        MediaSourceCacheIdentity.artworkKey(for: item, source: source)
    }

    func items(scope: String, key: String) -> [MediaItem]? {
        migrateIfNeeded()
        return read("items|\(scope)|\(key)", category: .library)
            .flatMap { try? JSONDecoder().decode([MediaItem].self, from: $0) }
    }

    func save(_ items: [MediaItem], scope: String, key: String, generation: UUID) {
        guard generation == libraryGeneration, items.allSatisfy({ $0.resource == nil }),
              let data = try? JSONEncoder().encode(items) else { return }
        migrateIfNeeded()
        write(data, key: "items|\(scope)|\(key)", category: .library)
    }

    func image(key: String) -> (Data?, UUID) {
        migrateIfNeeded()
        return (read("image|\(key)", category: .images), imageGeneration)
    }

    func image(key: String, ignoringLocalCache: Bool) -> (Data?, UUID) {
        if ignoringLocalCache { return (nil, imageGeneration) }
        migrateIfNeeded()
        return (read("image|\(key)", category: .images), imageGeneration)
    }

    func invalidateImageWrites() { imageGeneration = UUID() }

    func saveImage(_ data: Data, key: String, generation: UUID) {
        guard generation == imageGeneration else { return }
        write(data, key: "image|\(key)", category: .images)
    }

    func imageMetadata(key: String) -> (Data?, UUID) {
        migrateIfNeeded()
        return (read("image-metadata|\(key)", category: .images), imageGeneration)
    }

    func saveImageMetadata(_ data: Data, key: String, generation: UUID) {
        guard generation == imageGeneration else { return }
        write(data, key: "image-metadata|\(key)", category: .images)
    }

    func sizes() -> [AppCacheCategory: Int64] {
        migrateIfNeeded()
        var sizes = Dictionary(uniqueKeysWithValues: AppCacheCategory.allCases.filter { $0 != .shareInbox }.map { category in
            (category, files(in: folder(category)).reduce(0) { $0 + $1.bytes })
        })
        if let root = SharedVideoInbox.root {
            sizes[.shareInbox] = SharedVideoInbox.temporaryDirectories(in: root).reduce(0) { total, directory in
                total + files(in: directory).reduce(0) { $0 + $1.bytes }
            }
        }
        return sizes
    }

    func clear(_ categories: Set<AppCacheCategory>) -> Set<AppCacheCategory> {
        migrateIfNeeded()
        if categories.contains(.images) { imageGeneration = UUID() }
        if categories.contains(.library) { libraryGeneration = UUID() }
        var failures = Set<AppCacheCategory>()
        for category in categories {
            if category == .shareInbox {
                if let root = SharedVideoInbox.root, !SharedVideoInbox.clearTemporaryBatches(in: root) {
                    failures.insert(category)
                }
                continue
            }
            do {
                try FileManager.default.removeItem(at: folder(category))
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                continue
            } catch {
                failures.insert(category)
            }
        }
        return failures
    }

    private func folder(_ category: AppCacheCategory) -> URL {
        directory.appending(path: category.rawValue, directoryHint: .isDirectory)
    }

    private func file(_ key: String, category: AppCacheCategory) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder(category).appending(path: digest)
    }

    private func read(_ key: String, category: AppCacheCategory) -> Data? {
        try? Data(contentsOf: file(key, category: category))
    }

    private func write(_ data: Data, key: String, category: AppCacheCategory) {
        guard data.count <= 8 * 1024 * 1024 else { return }
        try? FileManager.default.createDirectory(at: folder(category), withIntermediateDirectories: true)
        try? data.write(to: file(key, category: category), options: .atomic)
        writes[category, default: 0] += 1
        if writes[category] == 1 || writes[category, default: 0].isMultiple(of: 32) {
            trim(category, limit: (category == .images ? 128 : 32) * 1024 * 1024)
        }
    }

    private func files(in folder: URL) -> [(url: URL, bytes: Int64, date: Date)] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else { return [] }
        var entries: [(URL, Int64, Date)] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            entries.append((url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        return entries
    }

    private func trim(_ category: AppCacheCategory, limit: Int64) {
        let entries = files(in: folder(category))
        var bytes = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries.sorted(by: { $0.date < $1.date }) where bytes > limit {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { bytes -= entry.bytes }
        }
    }

    private func migrateIfNeeded() {
        guard !migrated else { return }
        migrated = true
        let legacy = URL.cachesDirectory.appending(path: "EmbyMedia-v1", directoryHint: .isDirectory)
        let manager = FileManager.default
        for entry in files(in: legacy) {
            guard let handle = try? FileHandle(forReadingFrom: entry.url) else { continue }
            let firstByte = try? handle.read(upToCount: 1)
            try? handle.close()
            let category: AppCacheCategory = firstByte?.first == 91 ? .library : .images
            let folder = folder(category)
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appending(path: entry.url.lastPathComponent)
                if manager.fileExists(atPath: target.path) {
                    try manager.removeItem(at: entry.url)
                } else {
                    try manager.moveItem(at: entry.url, to: target)
                }
            } catch {
                // The old entry can be migrated on the next launch.
            }
        }
        if (try? manager.contentsOfDirectory(atPath: legacy.path).isEmpty) == true {
            try? manager.removeItem(at: legacy)
        }
    }
}
