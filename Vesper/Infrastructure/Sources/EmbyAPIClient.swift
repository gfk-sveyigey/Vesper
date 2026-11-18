import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct EmbySourceConfiguration: Codable, Equatable, Sendable {
    var title: String
    var note: String
    var serverAddress: String
    var username: String
    var serverID: String? = nil
    var userID: String? = nil
    var userAgent: String = "Vesper/1.0"
    var customHeaders: [String: String] = [:]
}

enum EmbyError: LocalizedError {
    case invalidAddress, invalidResponse, invalidHeader, insecureRemoteHTTP, authentication, forbidden, notFound, server(Int), missingAccount

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Emby 服务器地址无效。"
        case .invalidResponse: "Emby 服务器返回的数据无法识别。"
        case .invalidHeader: "自定义请求头无效，或试图覆盖 Vesper 管理的认证请求头。"
        case .insecureRemoteHTTP: "远程 Emby 服务器必须使用 HTTPS；HTTP 仅允许局域网地址。"
        case .authentication: "Emby 登录失败，请检查服务器、用户名和密码。"
        case .forbidden: "当前 Emby 用户没有访问此内容的权限。"
        case .notFound: "Emby 媒体不存在或已被移除。"
        case .server(let status): "Emby 请求失败（HTTP \(status)）。"
        case .missingAccount: "Emby 登录状态已失效，请重新登录。"
        }
    }
}

/// JSONSerialization produces immutable value graphs; never expose mutable containers.
struct EmbyJSON: @unchecked Sendable {
    let values: [String: Any]
    init(_ values: [String: Any]) { self.values = values }
    subscript(_ key: String) -> Any? { values[key] }
}

struct EmbyAPIClient: Sendable {
    let baseURL: URL
    let token: String?
    let deviceID: String
    let userAgent: String
    let customHeaders: [String: String]

    init(configuration: EmbySourceConfiguration, token: String?, deviceID: String) throws {
        let reserved = ["authorization", "x-emby-token", "x-emby-authorization", "host", "content-length", "user-agent", "connection", "transfer-encoding"]
        guard configuration.customHeaders.allSatisfy({ name, value in
            Self.isSafeHeaderName(name) && Self.isSafeHeaderValue(value) && !reserved.contains(name.lowercased())
        }) else { throw EmbyError.invalidHeader }
        guard let input = URL(string: configuration.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
              var components = URLComponents(url: input, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil, components.user == nil, components.password == nil else { throw EmbyError.invalidAddress }
        if components.scheme?.lowercased() == "http", !Self.isLocalHost(components.host ?? "") {
            throw EmbyError.insecureRemoteHTTP
        }
        let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !trimmedPath.split(separator: "/").contains("emby") {
            components.path = "/" + [trimmedPath, "emby"].filter { !$0.isEmpty }.joined(separator: "/")
        }
        components.query = nil; components.fragment = nil
        guard let baseURL = components.url else { throw EmbyError.invalidAddress }
        self.baseURL = baseURL
        self.token = token
        self.deviceID = deviceID
        self.userAgent = Self.safeHeaderValue(configuration.userAgent.isEmpty ? "Vesper/1.0" : configuration.userAgent)
        self.customHeaders = configuration.customHeaders.filter {
            let key = $0.key.lowercased()
            return !reserved.contains(key)
        }
    }

    func get(_ path: String, query: [String: String] = [:]) async throws -> EmbyJSON {
        try await send(path, method: "GET", query: query)
    }

    func send(_ path: String, method: String, query: [String: String] = [:], body: EmbyJSON? = nil) async throws -> EmbyJSON {
        var url = baseURL
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw EmbyError.invalidAddress }
        components.queryItems = query.isEmpty ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let requestURL = components.url else { throw EmbyError.invalidAddress }
        var request = URLRequest(url: requestURL, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
        request.setValue("MediaBrowser Client=\"Vesper\", Device=\"iPhone\", DeviceId=\"\(deviceID)\", Version=\"1.0\"",
                         forHTTPHeaderField: "X-Emby-Authorization")
        for (name, value) in customHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body.values)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await EmbyNetworkSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        switch response.statusCode {
        case 200..<300: break
        case 401: throw EmbyError.authentication
        case 403: throw EmbyError.forbidden
        case 404: throw EmbyError.notFound
        default: throw EmbyError.server(response.statusCode)
        }
        if data.isEmpty { return EmbyJSON([:]) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { return EmbyJSON(["Items": array]) }
            throw EmbyError.invalidResponse
        }
        return EmbyJSON(object)
    }

    func imageURL(itemID: String, tag: String?, width: Int = 600) -> URL? {
        var url = baseURL.appendingPathComponent("Items").appendingPathComponent(itemID).appendingPathComponent("Images").appendingPathComponent("Primary")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "maxWidth", value: String(width))]
        if let tag { components?.queryItems?.append(URLQueryItem(name: "tag", value: tag)) }
        if let token { components?.queryItems?.append(URLQueryItem(name: "api_key", value: token)) }
        url = components?.url ?? url
        return url
    }

    func delete(_ path: String, query: [String: String]) async throws {
        _ = try await send(path, method: "DELETE", query: query)
    }

    func mediaURL(_ path: String, query: [String: String] = [:]) throws -> URL {
        var url = baseURL
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw EmbyError.invalidAddress }
        parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let token { parts.queryItems?.append(URLQueryItem(name: "api_key", value: token)) }
        guard let result = parts.url else { throw EmbyError.invalidAddress }
        return result
    }

    func resolveMediaURL(_ path: String) throws -> URL {
        guard let parsed = URLComponents(string: path),
              !parsed.path.split(separator: "/").contains(".."), parsed.user == nil, parsed.password == nil else { throw EmbyError.invalidAddress }
        if parsed.host != nil, parsed.scheme == nil { throw EmbyError.invalidAddress }
        if parsed.scheme != nil {
            guard let url = parsed.url, sameOrigin(url) else { throw EmbyError.invalidAddress }
            return try addingToken(to: url)
        }
        // Server routes are rooted at /emby, even behind a reverse-proxy prefix.
        // Preserve the configured prefix rather than resolving against host root.
        var relative = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if relative.hasPrefix(basePath + "/") { relative.removeFirst(basePath.count + 1) }
        else if relative.hasPrefix("emby/") { relative.removeFirst(5) }
        var url = baseURL
        for component in relative.split(separator: "/") { url.appendPathComponent(String(component)) }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw EmbyError.invalidAddress }
        parts.queryItems = parsed.queryItems
        guard let result = parts.url else { throw EmbyError.invalidAddress }
        return try addingToken(to: result)
    }

    func sameOrigin(_ url: URL) -> Bool {
        url.scheme?.lowercased() == baseURL.scheme?.lowercased()
            && url.host?.lowercased() == baseURL.host?.lowercased()
            && (url.port ?? (url.scheme == "https" ? 443 : 80)) == (baseURL.port ?? (baseURL.scheme == "https" ? 443 : 80))
    }

    static func redacted(_ message: String) -> String {
        message.replacingOccurrences(of: #"(?i)((?:api_key|x-emby-token|access_token)=)[^&\s\"<>]+"#,
                                     with: "$1[redacted]", options: .regularExpression)
    }

    private func addingToken(to url: URL) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw EmbyError.invalidAddress }
        var query = parts.queryItems ?? []
        if let token, !query.contains(where: { ["api_key", "x-emby-token"].contains($0.name.lowercased()) }) {
            query.append(URLQueryItem(name: "api_key", value: token))
        }
        parts.queryItems = query
        guard let result = parts.url else { throw EmbyError.invalidAddress }
        return result
    }

    private static func safeHeaderValue(_ value: String) -> String {
        String(value.filter { $0 != "\r" && $0 != "\n" })
    }
    private static func isLocalHost(_ input: String) -> Bool {
        let host = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", "::1"].contains(host) || host.hasSuffix(".local") || host.hasSuffix(".lan")
            || host.hasSuffix(".home") || host.hasSuffix(".internal") { return true }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            return octets[0] == 10 || octets[0] == 127 || octets[0] == 192 && octets[1] == 168
                || octets[0] == 172 && (16...31).contains(octets[1])
                || octets[0] == 169 && octets[1] == 254
        }
        return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:")
    }
    private static func isSafeHeaderName(_ value: String) -> Bool {
        let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        return !value.isEmpty && value.utf8.allSatisfy { allowed.contains($0) }
    }
    private static func isSafeHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { $0 == 9 || ($0 >= 32 && $0 != 127) }
    }
}

/// Never forward account credentials or custom headers to a redirected origin.
final class EmbyNetworkSession: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = URLSession(configuration: .default, delegate: EmbyNetworkSession(), delegateQueue: nil)

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url,
              original.scheme?.lowercased() == target.scheme?.lowercased(),
              original.host?.lowercased() == target.host?.lowercased(),
              (original.port ?? (original.scheme == "https" ? 443 : 80)) == (target.port ?? (target.scheme == "https" ? 443 : 80)) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

