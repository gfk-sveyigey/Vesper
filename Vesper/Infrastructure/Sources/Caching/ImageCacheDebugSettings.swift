import Foundation

enum ImageCacheDebugSettings {
    static let ignoreLocalCacheKey = "debug.images.ignoreLocalCache"
    static var ignoresLocalCache: Bool { UserDefaults.standard.bool(forKey: ignoreLocalCacheKey) }
}

