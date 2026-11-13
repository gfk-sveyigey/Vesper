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
    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("Vesper.log")
    }
    @Published private(set) var storageError: String?
    private let writer = DispatchQueue(label: "com.aholic.vesper.log-writer", qos: .utility)
    private var retentionDays = 7
    private var pending: [RuntimeLogEntry] = []
    private var flushScheduled = false

    init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let text = (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""
        entries = text.split(separator: "\n").compactMap { line in
            guard let firstSpace = line.firstIndex(of: " "),
                  let date = formatter.date(from: String(line[..<firstSpace])) else { return nil }
            return RuntimeLogEntry(timestamp: date, message: String(line))
        }
        retentionDays = max(0, UserDefaults.standard.object(forKey: "runtimeLogs.retentionDays") as? Int ?? 7)
        pruneAndPersist()
    }

    func append(_ entry: String) {
        pending.append(RuntimeLogEntry(timestamp: Date(), message: entry))
        guard !flushScheduled else { return }
        flushScheduled = true
        // Never publish ObservableObject changes inside a UIKit layout/update callback.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let batch = self.pending
            self.entries.append(contentsOf: batch)
            self.pending.removeAll(keepingCapacity: true)
            if self.prune() {
                self.persist()
            } else {
                self.appendToFile(batch)
            }
        }
    }

    func setRetention(days: Int) {
        retentionDays = max(0, days)
        UserDefaults.standard.set(retentionDays, forKey: "runtimeLogs.retentionDays")
        pruneAndPersist()
    }

    func clear() {
        pending.removeAll()
        entries.removeAll()
        persist()
    }

    var exportText: String { entries.map(\.message).joined(separator: "\n") }

    func prepareExportFile(completion: @escaping @MainActor @Sendable (Result<URL, Error>) -> Void) {
        if !pending.isEmpty {
            entries.append(contentsOf: pending)
            pending.removeAll(keepingCapacity: true)
            flushScheduled = false
            _ = prune()
        }
        let content = exportText
        let text = content.isEmpty ? "" : content + "\n"
        let url = Self.fileURL
        writer.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                Task { @MainActor in completion(.success(url)) }
            } catch {
                Task { @MainActor in completion(.failure(error)) }
            }
        }
    }

    private func pruneAndPersist() {
        _ = prune()
        persist()
    }

    @discardableResult
    private func prune() -> Bool {
        let originalCount = entries.count
        if retentionDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
            entries.removeAll { $0.timestamp < cutoff }
        }
        return entries.count != originalCount
    }

    private func appendToFile(_ batch: [RuntimeLogEntry]) {
        guard !batch.isEmpty else { return }
        let url = Self.fileURL
        let text = batch.map(\.message).joined(separator: "\n") + "\n"
        writer.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    let file = try FileHandle(forWritingTo: url)
                    defer { try? file.close() }
                    try file.seekToEnd()
                    try file.write(contentsOf: Data(text.utf8))
                } else {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                Task { @MainActor [weak self] in self?.storageError = "日志文件写入失败。" }
            }
        }
    }

    private func persist() {
        let content = exportText
        let text = content.isEmpty ? "" : content + "\n"
        let url = Self.fileURL
        writer.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Task { @MainActor [weak self] in
                    self?.storageError = "日志文件写入失败。"
                }
            }
        }
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
