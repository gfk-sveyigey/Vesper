import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct DanmakuAPISource: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var address: String
    var enabled = true

    func endpoint(_ path: [String], query: [URLQueryItem] = []) throws -> URL {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var parts = URLComponents(string: normalized),
              parts.scheme == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              var url = parts.url else { throw DanmakuAPIError.invalidAddress }
        // Preserve reverse-proxy prefixes and path-based access tokens.
        if !url.path.hasSuffix("/api/v2") { url = url.appendingPathComponent("api/v2") }
        for component in path { url = url.appendingPathComponent(component) }
        parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        guard let result = parts.url else { throw DanmakuAPIError.invalidAddress }
        return result
    }
}

enum DanmakuAPIError: LocalizedError {
    case invalidAddress, response, http(Int), empty
    var errorDescription: String? {
        switch self {
        case .invalidAddress: VesperLocalization.string("请输入有效的 HTTPS API 基础地址，可包含路径前缀，不包含查询参数。")
        case .response: VesperLocalization.string("弹幕 API 返回的数据无效或接口不兼容。")
        case .http(let status): String(format: VesperLocalization.string("弹幕 API 请求失败（HTTP %d）。"), status)
        case .empty: VesperLocalization.string("该剧集暂无可显示的弹幕。")
        }
    }
}

struct DanmakuAPIItem: Identifiable, Sendable {
    let id: String
    let title: String
}

enum DanmakuAPI {
    static func data(source: DanmakuAPISource, path: [String], query: [URLQueryItem] = []) async throws -> Data {
        let url = try source.endpoint(path, query: query)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        #if canImport(FoundationNetworking)
        let (downloaded, response) = try await session.data(for: request)
        #else
        let (bytes, response) = try await session.bytes(for: request)
        #endif
        guard let http = response as? HTTPURLResponse else { throw DanmakuAPIError.response }
        guard (200..<300).contains(http.statusCode) else { throw DanmakuAPIError.http(http.statusCode) }
        let limit = 16 * 1024 * 1024
        guard response.expectedContentLength <= Int64(limit) else { throw DanmakuImportError.tooLarge }
        #if canImport(FoundationNetworking)
        guard downloaded.count <= limit else { throw DanmakuImportError.tooLarge }
        return downloaded
        #else
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw DanmakuImportError.tooLarge }
            data.append(byte)
        }
        return data
        #endif
    }

    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["success"] as? Bool != false else { throw DanmakuAPIError.response }
        return object
    }
    static func items(_ array: Any?, id key: String, title: String) -> [DanmakuAPIItem] {
        (array as? [[String: Any]] ?? []).compactMap { row in
            let id: String
            if let value = row[key] as? String { id = value }
            else if let value = row[key] as? NSNumber { id = value.stringValue }
            else { return nil }
            guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else { return nil }
            return .init(id: id, title: row[title] as? String ?? id)
        }
    }
    static func search(source: DanmakuAPISource, keyword: String) async throws -> [DanmakuAPIItem] {
        let result = try object(await data(source: source, path: ["search", "anime"], query: [.init(name: "keyword", value: keyword)]))
        return items(result["animes"], id: "animeId", title: "animeTitle")
    }
    static func episodes(source: DanmakuAPISource, id: String) async throws -> [DanmakuAPIItem] {
        let result = try object(await data(source: source, path: ["bangumi", id]))
        let bangumi = result["bangumi"] as? [String: Any]
        return items(bangumi?["episodes"], id: "episodeId", title: "episodeTitle")
    }
    static func comments(source: DanmakuAPISource, id: String) async throws -> [DanmakuComment] {
        let bytes = try await data(source: source, path: ["comment", id], query: [.init(name: "format", value: "json")])
        return try parseComments(bytes)
    }
    static func parseComments(_ data: Data) throws -> [DanmakuComment] {
        guard data.count <= 16 * 1024 * 1024 else { throw DanmakuImportError.tooLarge }
        let result = try object(data)
        guard let rows = result["comments"] as? [[String: Any]] else { throw DanmakuAPIError.response }
        guard rows.count <= 50_000 else { throw DanmakuImportError.tooLarge }
        let comments: [DanmakuComment] = rows.compactMap { row in
            guard let p = row["p"] as? String, let text = row["m"] as? String else { return nil }
            let fields = p.components(separatedBy: ",")
            guard fields.count >= 3, let time = Double(fields[0]), time.isFinite, time >= 0,
                  let mode = Int(fields[1]), [1,2,3,4,5].contains(mode),
                  let color = UInt32(fields[2]), color <= 0xFFFFFF else { return nil }
            let content = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            guard !content.isEmpty else { return nil }
            return .init(time: time, mode: mode, color: color, text: content)
        }
        guard !comments.isEmpty else { throw DanmakuAPIError.empty }
        return comments.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
    }
}
