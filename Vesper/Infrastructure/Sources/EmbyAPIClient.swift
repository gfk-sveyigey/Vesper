import Foundation
#if canImport(UIKit)
import UIKit
#endif
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
    var customHeaders: [String: String] = [:]
    // Optional fields keep configurations created by older builds decodable.
    var alternateAddresses: [String]? = nil
    var primaryRouteAddress: String? = nil
    var alternateRouteNames: [String: String]? = nil
    var serverRouteAddresses: [String]? = nil

    var primaryRoute: String { primaryRouteAddress ?? serverAddress }

    var backupRoutes: [String] {
        let addresses = EmbyRouteOptions.unique((alternateAddresses ?? []) + [serverAddress])
            .filter { EmbyRouteOptions.key($0) != EmbyRouteOptions.key(primaryRoute) }
        let serverKeys = Set((serverRouteAddresses ?? []).map(EmbyRouteOptions.key))
        let manual = addresses.filter { !serverKeys.contains(EmbyRouteOptions.key($0)) }
        let available = Set(addresses.map(EmbyRouteOptions.key))
        let server = EmbyRouteOptions.unique(serverRouteAddresses ?? [])
            .filter { available.contains(EmbyRouteOptions.key($0)) }
        return manual + server
    }
    var syncPlaybackProgress: Bool? = nil
    var syncWatchedState: Bool? = nil
    var allowServerTranscoding: Bool? = nil
    var fetchAlternateAddresses: Bool? = nil
    var iconData: Data? = nil
    var strmDirectPlayback: Bool? = nil

    mutating func mergeServerRoutes(_ routes: [EmbyServerRoute]) {
        let primaryKey = EmbyRouteOptions.key(primaryRoute)
        let backups = routes.filter { EmbyRouteOptions.key($0.address) != primaryKey }
        let previousServerKeys = Set((serverRouteAddresses ?? []).map(EmbyRouteOptions.key))
        let manual = backupRoutes.filter { !previousServerKeys.contains(EmbyRouteOptions.key($0)) }
        let manualKeys = Set(manual.map(EmbyRouteOptions.key))
        serverRouteAddresses = EmbyRouteOptions.unique((serverRouteAddresses ?? []) + backups.map(\.address))
            .filter { EmbyRouteOptions.key($0) != primaryKey && !manualKeys.contains(EmbyRouteOptions.key($0)) }
        alternateAddresses = EmbyRouteOptions.unique([primaryRoute] + manual + (serverRouteAddresses ?? []))
        var names = alternateRouteNames ?? [:]
        for route in backups {
            let key = EmbyRouteOptions.key(route.address)
            // Keep user-edited labels when refreshing server-provided routes.
            if names[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                names[key] = route.name
            }
        }
        alternateRouteNames = names
    }
}

struct EmbyServerRoute: Equatable, Sendable {
    let name: String
    let address: String
}

enum EmbyRouteOptions {
    static func key(_ address: String) -> String {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = EmbySourceConfiguration(title: "", note: "", serverAddress: value, username: "")
        guard let url = try? EmbyAPIClient(configuration: configuration, token: nil, deviceID: "validation").baseURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return value }
        components.host = components.host?.lowercased()
        components.scheme = components.scheme?.lowercased()
        if components.scheme == "https" && components.port == 443 || components.scheme == "http" && components.port == 80 { components.port = nil }
        return (components.string ?? value).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    static func unique(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(key($0)).inserted }
    }
}

enum EmbyUserAgentPolicy {
    static let enabledKey = "debug.emby.clientSimulation.enabled"
    static let nameKey = "debug.emby.clientSimulation.name"
    static let versionKey = "debug.emby.clientSimulation.version"
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    enum RequestKind: Equatable { case api, image, playback }

    static var defaultValue: String { "Vesper/" + appVersion }
    static var clientName: String {
        let value = UserDefaults.standard.string(forKey: nameKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UserDefaults.standard.bool(forKey: enabledKey) && isSafe(value) ? value : "Vesper"
    }
    static var clientVersion: String {
        let value = UserDefaults.standard.string(forKey: versionKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UserDefaults.standard.bool(forKey: enabledKey) && isSafe(value) ? value : appVersion
    }
    static func userAgent(for kind: RequestKind) -> String {
        let base = "\(clientName)/\(clientVersion)"
        #if canImport(UIKit)
        if kind == .image && !UserDefaults.standard.bool(forKey: enabledKey) {
            return "\(base) (iPhone; iOS \(UIDevice.current.systemVersion); Scale/\(String(format: "%.2f", UIScreen.main.scale)))"
        }
        #endif
        return base
    }
    static func defaultValue(for kind: RequestKind) -> String {
        #if canImport(UIKit)
        if kind == .image {
            return "\(defaultValue) (iPhone; iOS \(UIDevice.current.systemVersion); Scale/\(String(format: "%.2f", UIScreen.main.scale)))"
        }
        return defaultValue
        #else
        defaultValue
        #endif
    }
    private static func isSafe(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 32 && $0 != 127 }
    }
}

enum EmbyError: LocalizedError {
    case invalidAddress, invalidResponse, invalidHeader, insecureRemoteHTTP, authentication, forbidden, notFound, server(Int), missingAccount

    var errorDescription: String? {
        switch self {
        case .invalidAddress: VesperLocalization.string("Emby 服务器地址无效。")
        case .invalidResponse: VesperLocalization.string("Emby 服务器返回的数据无法识别。")
        case .invalidHeader: VesperLocalization.string("自定义 UA 或请求头无效，或试图覆盖 Vesper 管理的认证请求头。")
        case .insecureRemoteHTTP: VesperLocalization.string("远程 Emby 服务器必须使用 HTTPS；HTTP 仅允许局域网地址。")
        case .authentication: VesperLocalization.string("Emby 登录失败，请检查服务器、用户名和密码。")
        case .forbidden: VesperLocalization.string("当前 Emby 用户没有访问此内容的权限。")
        case .notFound: VesperLocalization.string("Emby 媒体不存在或已被移除。")
        case .server(let status): String(format: VesperLocalization.string("Emby 请求失败（HTTP %d）。"), status)
        case .missingAccount: VesperLocalization.string("Emby 登录状态已失效，请重新登录。")
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
    var userAgent: String { EmbyUserAgentPolicy.userAgent(for: .api) }
    let userID: String?
    let customHeaders: [String: String]

    init(configuration: EmbySourceConfiguration, token: String?, deviceID: String) throws {
        let reserved = ["authorization", "x-emby-token", "x-emby-authorization", "host", "content-length", "connection", "transfer-encoding"]
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
        self.userID = configuration.userID
        self.customHeaders = configuration.customHeaders.filter {
            let key = $0.key.lowercased()
            return key != "user-agent" && !reserved.contains(key)
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
        for (name, value) in requestHeaders(accept: "application/json", kind: .api) {
            request.setValue(value, forHTTPHeaderField: name)
        }
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

    /// Shared API/image identity; transport headers are managed by URLSession.
    func requestHeaders(accept: String, kind: EmbyUserAgentPolicy.RequestKind = .api) -> [String: String] {
        func quoted(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        var identity = [("Client", EmbyUserAgentPolicy.clientName), ("Device", "iPhone"),
                        ("DeviceId", deviceID), ("Version", EmbyUserAgentPolicy.clientVersion)]
        if let userID { identity.insert(("UserId", userID), at: 0) }
        var headers = customHeaders
        headers["User-Agent"] = EmbyUserAgentPolicy.userAgent(for: kind)
        headers["Accept"] = accept
        headers["Accept-Language"] = Locale.preferredLanguages.prefix(5).enumerated().map {
            $0.offset == 0 ? $0.element : "\($0.element);q=\(String(format: "%.1f", 1 - Double($0.offset) * 0.1))"
        }.joined(separator: ",")
        headers["Authorization"] = "Emby " + identity.map { "\($0.0)=\"\(quoted($0.1))\"" }.joined(separator: ", ")
        if let token { headers["X-Emby-Token"] = token }
        return headers
    }

    /// Media URLs carry the Emby token. Keep API identity headers out of native
    /// players that cannot inject arbitrary HTTP headers (SwiftVLC 1.0.0).
    /// Explicit proxy headers are retained so unsupported authentication fails
    /// safely instead of silently playing without required credentials.
    func playbackHeaders() -> [String: String] {
        var headers = customHeaders
        headers["User-Agent"] = EmbyUserAgentPolicy.userAgent(for: .playback)
        return headers
    }

    func imageURL(itemID: String, tag: String?, width: Int = 640, type: String = "Primary", index: Int? = nil) -> URL? {
        var url = baseURL.appendingPathComponent("Items").appendingPathComponent(itemID).appendingPathComponent("Images").appendingPathComponent(type)
        if let index { url.appendPathComponent(String(index)) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "maxWidth", value: String(width))]
        if let tag { components?.queryItems?.append(URLQueryItem(name: "tag", value: tag)) }
        components?.queryItems?.append(URLQueryItem(name: "quality", value: "90"))
        url = components?.url ?? url
        return url
    }

    func delete(_ path: String, query: [String: String]) async throws {
        _ = try await send(path, method: "DELETE", query: query)
    }

    func mediaURL(_ path: String, query: [String: String] = [:], includeToken: Bool = true) throws -> URL {
        var url = baseURL
        for component in path.split(separator: "/") { url.appendPathComponent(String(component)) }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw EmbyError.invalidAddress }
        parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if includeToken, let token { parts.queryItems?.append(URLQueryItem(name: "api_key", value: token)) }
        guard let result = parts.url else { throw EmbyError.invalidAddress }
        return result
    }

    func resolveMediaURL(_ path: String, includeToken: Bool = false) throws -> URL {
        guard let parsed = URLComponents(string: path),
              !parsed.path.split(separator: "/").contains(".."), parsed.user == nil, parsed.password == nil else { throw EmbyError.invalidAddress }
        if parsed.host != nil, parsed.scheme == nil { throw EmbyError.invalidAddress }
        if parsed.scheme != nil {
            guard let url = parsed.url, sameOrigin(url) else { throw EmbyError.invalidAddress }
            return try addingToken(to: url, includeToken: includeToken)
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
        return try addingToken(to: result, includeToken: includeToken)
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

    private func addingToken(to url: URL, includeToken: Bool) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw EmbyError.invalidAddress }
        var query = parts.queryItems ?? []
        if includeToken, let token, !query.contains(where: { ["api_key", "x-emby-token"].contains($0.name.lowercased()) }) {
            query.append(URLQueryItem(name: "api_key", value: token))
        }
        parts.queryItems = query
        guard let result = parts.url else { throw EmbyError.invalidAddress }
        return result
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
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Vesper manages metadata and artwork explicitly so they can be cleared by category.
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: EmbyNetworkSession(), delegateQueue: nil)
    }()

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

