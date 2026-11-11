import Foundation
import OSLog

/// Unified Logging owns timestamps, levels and persistence; avoid duplicate file logs.
enum AppLog {
    enum Category: String {
        case lifecycle, navigation, sources, media, playback, services
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.aholic.vesper"

    static func info(_ event: String, category: Category, detail: String = "") {
        Logger(subsystem: subsystem, category: category.rawValue)
            .info("\(event, privacy: .public) \(detail, privacy: .private)")
    }

    static func debug(_ event: String, category: Category, detail: String = "") {
        #if DEBUG
        Logger(subsystem: subsystem, category: category.rawValue)
            .debug("\(event, privacy: .public) \(detail, privacy: .private)")
        #endif
    }

    static func error(_ event: String, category: Category, error: any Error) {
        let underlying = error as NSError
        // Do not log descriptions/userInfo: these can contain URLs or credentials.
        Logger(subsystem: subsystem, category: category.rawValue)
            .error("\(event, privacy: .public) domain=\(underlying.domain, privacy: .private) code=\(underlying.code)")
    }
}
