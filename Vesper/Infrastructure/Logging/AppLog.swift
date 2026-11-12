import Foundation
import OSLog
import Combine

/// Unified Logging owns timestamps, levels and persistence; avoid duplicate file logs.
@MainActor
enum AppLog {
    enum Category: String {
        case lifecycle, navigation, sources, media, playback, services
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.aholic.vesper"
    static let runtimeEntries = RuntimeLogEntries()

    static func trace(_ event: String, detail: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        runtimeEntries.append("\(formatter.string(from: Date())) \(event) \(detail)")
    }

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

@MainActor
final class RuntimeLogEntries: ObservableObject {
    @Published private(set) var entries: [RuntimeLogEntry]
    private let entriesKey = "runtimeLogs.entries"
    private var retentionDays = 7
    private var maximumCount = 500

    init() {
        if let data = UserDefaults.standard.data(forKey: entriesKey),
           let saved = try? JSONDecoder().decode([RuntimeLogEntry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
        retentionDays = max(1, UserDefaults.standard.integer(forKey: "runtimeLogs.retentionDays").nonzeroOr(7))
        maximumCount = max(1, UserDefaults.standard.integer(forKey: "runtimeLogs.maximumCount").nonzeroOr(500))
        pruneAndPersist()
    }

    func append(_ entry: String) {
        entries.append(RuntimeLogEntry(timestamp: Date(), message: entry))
        pruneAndPersist()
    }

    func setRetention(days: Int, count: Int) {
        retentionDays = max(1, days)
        maximumCount = max(1, count)
        UserDefaults.standard.set(retentionDays, forKey: "runtimeLogs.retentionDays")
        UserDefaults.standard.set(maximumCount, forKey: "runtimeLogs.maximumCount")
        pruneAndPersist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    var exportText: String { entries.map(\.message).joined(separator: "\n") }

    private func pruneAndPersist() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        entries.removeAll { $0.timestamp < cutoff }
        if entries.count > maximumCount {
            entries.removeFirst(entries.count - maximumCount)
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: entriesKey)
    }
}

struct RuntimeLogEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let message: String

    init(id: UUID = UUID(), timestamp: Date, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
    }
}

private extension Int {
    func nonzeroOr(_ fallback: Int) -> Int { self == 0 ? fallback : self }
}
