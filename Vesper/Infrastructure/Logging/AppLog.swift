import Foundation
import Combine
import VesperAetherBridge
import VesperVLCBridge

/// Shared runtime storage and process-wide playback-engine log forwarding.
@MainActor
enum AppLog {
    static let runtimeEntries = RuntimeLogEntries()
    private static let engineBuffer = EngineLogBuffer()
    private static var engineLoggingInstalled = false

    static func installEngineLogging() {
        guard !engineLoggingInstalled else { return }
        engineLoggingInstalled = true
        let buffer = engineBuffer
        AetherDriver.setLogHandler { buffer.append($0) }
        VLCDriver.setLogHandler { buffer.append($0) }
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
        let wholeSecondsFormatter = ISO8601DateFormatter()
        let text = (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""
        entries = text.split(separator: "\n").compactMap { line in
            guard let firstSpace = line.firstIndex(of: " "),
                  let date = formatter.date(from: String(line[..<firstSpace]))
                    ?? wholeSecondsFormatter.date(from: String(line[..<firstSpace])) else { return nil }
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

/// Engine callbacks may run on decoder/network threads. Bound the pending batch
/// and publish at most four batches a second instead of dispatching per log line.
private final class EngineLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.aholic.vesper.engine-logs", qos: .utility)
    private var pending: [(Date, String)] = []
    private var scheduled = false
    private var dropped = 0

    func append(_ message: String) {
        lock.lock()
        if pending.count < 1_000 {
            pending.append((Date(), String(message.prefix(8_192))))
        } else {
            dropped += 1
        }
        let needsFlush = !scheduled
        scheduled = true
        lock.unlock()
        if needsFlush {
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [self] in flush() }
        }
    }

    private func flush() {
        lock.lock()
        let batch = pending
        let skipped = dropped
        pending.removeAll(keepingCapacity: true)
        dropped = 0
        scheduled = false
        lock.unlock()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = batch.map { date, message in
            "\(formatter.string(from: date)) \(Self.redacted(message))"
        }
        if skipped > 0 {
            lines.append("\(formatter.string(from: Date())) [EngineLogs] Suppressed \(skipped) excess log entries")
        }
        let entries = lines
        Task { @MainActor in
            for line in entries { AppLog.runtimeEntries.append(line) }
        }
    }

    // Upstream VLC logs can contain complete request URLs or HTTP headers.
    // Redact all query values, not just Emby's known token parameter names.
    static func redacted(_ message: String) -> String {
        var text = message
        let rules: [(String, String)] = [
            (#"(?i)(https?://)[^/\s@]+@"#, "$1[redacted]@"),
            (#"([?&][^=&\s\"'<>]+?=)[^&\s\"'<>]*"#, "$1[redacted]"),
            (#"(?im)(\b(?:authorization|proxy-authorization|cookie|set-cookie)[\"']?\s*[:=]\s*)[^\r\n]*"#, "$1[redacted]"),
            (#"(?i)(\b(?:api[_-]?key|x-emby-token|x-mediabrowser-token|access[_-]?token|refresh[_-]?token|token|password|passwd|pw)[\"']?\s*[:=]\s*)[\"']?[^&\s\"'<>;,}]+"#, "$1[redacted]")
        ]
        for (pattern, replacement) in rules {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
