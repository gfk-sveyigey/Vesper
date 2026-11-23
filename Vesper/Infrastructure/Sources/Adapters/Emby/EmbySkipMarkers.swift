import Foundation
import PlaybackContracts

enum EmbySkipSettings {
    static let introKey = "emby.skip.intro"
    static let outroKey = "emby.skip.outro"
    static let bodyPreloadKey = "emby.preload.bodyDuration"
    static let databasesKey = "emby.skip.databases.v1"
    static var introEnabled: Bool { UserDefaults.standard.bool(forKey: introKey) }
    static var outroEnabled: Bool { UserDefaults.standard.bool(forKey: outroKey) }
    static var databases: [EmbySkipDatabase] {
        let saved = UserDefaults.standard.string(forKey: databasesKey) ?? ""
        let decoded = (try? JSONDecoder().decode([EmbySkipDatabase].self, from: Data(saved.utf8))) ?? []
        var result: [EmbySkipDatabase] = []
        var seen = Set<String>()
        for entry in decoded where seen.insert(entry.id).inserted {
            if var builtin = EmbySkipDatabase.builtins.first(where: { $0.id == entry.id }) {
                builtin.enabled = entry.enabled
                result.append(builtin)
            } else if !entry.id.hasPrefix("builtin-") { result.append(entry) }
        }
        result += EmbySkipDatabase.builtins.filter { !seen.contains($0.id) }
        return result
    }
    static func save(_ databases: [EmbySkipDatabase]) {
        guard let data = try? JSONEncoder().encode(databases) else { return }
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: databasesKey)
    }
}

struct EmbySkipDatabase: Identifiable, Codable, Hashable, Sendable {
    enum Format: String, Codable, CaseIterable, Identifiable, Sendable {
        case introDB, theIntroDB
        var id: String { rawValue }
        var title: String { self == .introDB ? "IntroDB" : "TheIntroDB" }
    }
    var id: String = UUID().uuidString
    var name: String
    var address: String
    var format: Format
    var enabled = true
    var isBuiltin: Bool { Self.builtins.contains { $0.id == id } }
    static let builtins: [Self] = [
        .init(id: "builtin-introdb", name: "IntroDB", address: "https://api.introdb.app", format: .introDB),
        .init(id: "builtin-theintrodb", name: "TheIntroDB", address: "https://api.theintrodb.org/v4", format: .theIntroDB)
    ]
}

struct EmbySkipIdentity: Sendable {
    let providers: [String: String]
    let season: Int?
    let episode: Int?
    func provider(_ name: String) -> String? {
        providers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct EmbySkipMarkers: Sendable {
    struct Interval: Sendable, Equatable { let start: Double; let end: Double }
    var intros: [Interval] = []
    var creditsStart: Double? = nil
    static let empty = Self()
    var hasData: Bool { !intros.isEmpty || creditsStart != nil }

    func preloadPosition(duration: Double, fraction: Double, introEnabled: Bool, outroEnabled: Bool) -> Double {
        let introDuration = introEnabled ? intros.reduce(0) { $0 + $1.end - $1.start } : 0
        let outroDuration = outroEnabled ? creditsStart.map { max(0, duration - $0) } ?? 0 : 0
        return min(duration, max(0, duration - introDuration - outroDuration) * fraction + introDuration)
    }

    static func decode(_ data: Data, format: EmbySkipDatabase.Format, duration: Double) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .empty }
        func rows(_ key: String) -> [[String: Any]] {
            if let values = root[key] as? [[String: Any]] { return values }
            return (root[key] as? [String: Any]).map { [$0] } ?? []
        }
        func seconds(_ row: [String: Any], _ key: String) -> Double? {
            guard let number = row[key + "_ms"] as? NSNumber else { return nil }
            let value = number.doubleValue / 1000
            return value.isFinite && value >= 0 ? value : nil
        }
        let intros = rows("intro").compactMap { row -> Interval? in
            let start = seconds(row, "start") ?? 0
            guard let end = seconds(row, "end"), end > start, end < duration else { return nil }
            return Interval(start: start, end: end)
        }.sorted { $0.start < $1.start }
        // Collapse overlaps so body-duration preloading never subtracts the same time twice.
        var merged: [Interval] = []
        for interval in intros {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = Interval(start: last.start, end: max(last.end, interval.end))
            } else { merged.append(interval) }
        }
        let credits = rows(format == .introDB ? "outro" : "credits").compactMap { row -> Double? in
            guard let start = seconds(row, "start"), start > 0, start < duration,
                  start >= (merged.last?.end ?? 0) else { return nil }
            if let end = seconds(row, "end"), end <= start { return nil }
            return start
        }.min()
        return Self(intros: merged, creditsStart: credits)
    }
}

actor EmbySkipLookup {
    static let shared = EmbySkipLookup()
    private var pending: [String: Task<EmbySkipMarkers, Never>] = [:]
    private var cached: [String: (Date, EmbySkipMarkers)] = [:]
    private let session = URLSession(configuration: .ephemeral)

    func markers(for item: MediaItem, source: MediaSource, duration: Double) async -> EmbySkipMarkers {
        guard source.kind == .emby, duration.isFinite, duration > 0, duration < Double(Int64.max) / 1000,
              EmbySkipSettings.introEnabled || EmbySkipSettings.outroEnabled else {
            await log("跳过标记查询略过：来源、时长无效或片头片尾功能均已关闭")
            return .empty
        }
        let databases = EmbySkipSettings.databases.filter(\.enabled)
        guard !databases.isEmpty else {
            await log("未查询跳过标记：没有启用的数据库")
            return .empty
        }
        let fingerprint = (try? JSONEncoder().encode(databases)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let key = "\(AppCacheStore.scope(for: source))|\(item.id.localID)|\(item.embyMediaSourceID ?? "")|\(Int(duration))|\(fingerprint)"
        if let (date, value) = cached[key], Date().timeIntervalSince(date) < 600 {
            await log("使用缓存的片头片尾标记：片头段数=\(value.intros.count)，片尾起点=\(value.creditsStart.map { String($0) } ?? "无")")
            return value
        }
        if let task = pending[key] {
            await log("等待相同媒体的片头片尾查询完成")
            return await task.value
        }
        let task = Task { await self.fetch(item, source: source, duration: duration, databases: databases) }
        pending[key] = task
        let value = await task.value
        pending[key] = nil
        if cached.count >= 100 { cached.removeAll() }
        cached[key] = (Date(), value)
        await log("片头片尾查询结束：片头段数=\(value.intros.count)，片尾起点=\(value.creditsStart.map { String($0) } ?? "无")")
        return value
    }

    private func fetch(_ item: MediaItem, source: MediaSource, duration: Double, databases: [EmbySkipDatabase]) async -> EmbySkipMarkers {
        await log("开始查询片头片尾：媒体=\(item.id.localID)，时长=\(duration)，启用数据库数=\(databases.count)")
        let identity: EmbySkipIdentity
        do {
            guard let value = try await EmbyRepository.shared.skipIdentity(for: item, source: source) else {
                await log("无法从 Emby 获取片头片尾查询所需的媒体身份信息")
                return .empty
            }
            identity = value
        } catch {
            await log("获取媒体身份信息失败：\(error.localizedDescription)")
            return .empty
        }
        for database in databases {
            guard !Task.isCancelled else { return .empty }
            guard var url = URL(string: database.address), url.scheme?.lowercased() == "https",
                  url.host != nil, url.user == nil, url.password == nil else {
                await log("数据库 \(database.name) 地址无效，跳过")
                continue
            }
            var query: [String: String] = [:]
            switch database.format {
            case .introDB:
                guard let imdb = identity.provider("Imdb"), !imdb.isEmpty else {
                    await log("数据库 \(database.name) 缺少 IMDb ID，无法查询")
                    continue
                }
                query["imdb_id"] = imdb
                if let season = identity.season, let episode = identity.episode {
                    guard season > 0, episode > 0 else {
                        await log("数据库 \(database.name) 的季数或集数无效，跳过")
                        continue
                    }
                    query["season"] = String(season); query["episode"] = String(episode)
                } else { query["is_movie"] = "true" }
                url.appendPathComponent("segments")
            case .theIntroDB:
                if !url.path.split(separator: "/").contains("v4") { url.appendPathComponent("v4") }
                url.appendPathComponent("media")
                for (provider, parameter) in [("Tvdb", "tvdb_id"), ("Tmdb", "tmdb_id"), ("Imdb", "imdb_id")] {
                    if let id = identity.provider(provider), !id.isEmpty { query[parameter] = id; break }
                }
                guard !query.isEmpty else {
                    await log("数据库 \(database.name) 缺少受支持的媒体 ID，无法查询")
                    continue
                }
                if let season = identity.season, let episode = identity.episode {
                    query["season"] = String(season); query["episode"] = String(episode)
                }
                query["duration_ms"] = String(Int64(duration * 1000))
            }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let endpoint = components.url else {
                await log("数据库 \(database.name) 无法生成查询地址，跳过")
                continue
            }
            // Never forward Emby authentication or custom source headers to a third-party database.
            var request = URLRequest(url: endpoint, timeoutInterval: 10)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            await log("查询数据库 \(database.name)，格式=\(database.format.title)，季=\(identity.season.map { String($0) } ?? "无")，集=\(identity.episode.map { String($0) } ?? "无")")
            do {
                let (data, response) = try await session.data(for: request)
                guard let status = (response as? HTTPURLResponse)?.statusCode else {
                    await log("数据库 \(database.name) 未返回 HTTP 响应")
                    continue
                }
                guard status == 200 else {
                    await log("数据库 \(database.name) 返回 HTTP \(status)")
                    continue
                }
                guard data.count <= 1_000_000 else {
                    await log("数据库 \(database.name) 响应过大，已忽略：\(data.count) bytes")
                    continue
                }
                let markers = try EmbySkipMarkers.decode(data, format: database.format, duration: duration)
                await log("数据库 \(database.name) 响应已解析：片头段数=\(markers.intros.count)，片尾起点=\(markers.creditsStart.map { String($0) } ?? "无")")
                if markers.hasData { return markers }
            } catch {
                await log("数据库 \(database.name) 请求或解析失败：\(error.localizedDescription)")
            }
        }
        return .empty
    }

    private func log(_ message: String) async {
        await MainActor.run {
            AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [IntroOutro] \(EmbyAPIClient.redacted(message))")
        }
    }
}
