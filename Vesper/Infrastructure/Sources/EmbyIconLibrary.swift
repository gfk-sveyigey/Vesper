import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct EmbyIconLibraryLink: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var address: String
}

struct EmbyLibraryIcon: Identifiable, Equatable, Sendable {
    let name: String
    let url: URL
    var id: String { url.absoluteString }
}

struct EmbyIconCatalog: Sendable {
    let name: String
    let description: String
    let icons: [EmbyLibraryIcon]

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 3 * 1024 * 1024,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = object["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rows = object["icons"] as? [[String: Any]], rows.count <= 10_000 else {
            throw EmbyIconLibraryError.invalidCatalog
        }
        var seen = Set<String>()
        let icons: [EmbyLibraryIcon] = rows.compactMap { row in
            guard let rawName = row["name"] as? String,
                  !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let address = row["url"] as? String,
                  let url = try? EmbyIconLibraryClient.url(address),
                  seen.insert(url.absoluteString).inserted else { return nil }
            return .init(name: String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)), url: url)
        }
        guard !icons.isEmpty else { throw EmbyIconLibraryError.invalidCatalog }
        return .init(name: String(name.prefix(200)),
                     description: String((object["description"] as? String ?? "").prefix(2000)), icons: icons)
    }
}

enum EmbyIconLibraryError: LocalizedError {
    case invalidAddress, invalidCatalog, download, invalidImage
    var errorDescription: String? {
        switch self {
        case .invalidAddress: VesperLocalization.string("请输入有效的 HTTPS 图标库链接。")
        case .invalidCatalog: VesperLocalization.string("图标库格式无效，或没有可用的图标。")
        case .download: VesperLocalization.string("图标库或图片下载失败，请检查链接与网络后重试。")
        case .invalidImage: VesperLocalization.string("无法读取此图标，请选择其他图标。")
        }
    }
}

/// Isolated from all Emby sessions: no server tokens, cookies or custom headers.
enum EmbyIconLibraryClient {
    static func url(_ address: String) throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { throw EmbyIconLibraryError.invalidAddress }
        return url
    }

    static func catalog(at address: String) async throws -> EmbyIconCatalog {
        try EmbyIconCatalog.parse(await data(from: url(address), limit: 3 * 1024 * 1024))
    }

    static func data(from url: URL, limit: Int) async throws -> Data {
        _ = try self.url(url.absoluteString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: HTTPSRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        #if canImport(FoundationNetworking)
        let (downloaded, response) = try await session.data(from: url)
        #else
        let (bytes, response) = try await session.bytes(from: url)
        #endif
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= Int64(limit) else { throw EmbyIconLibraryError.download }
        #if canImport(FoundationNetworking)
        guard downloaded.count <= limit else { throw EmbyIconLibraryError.download }
        return downloaded
        #else
        var result = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard result.count < limit else { throw EmbyIconLibraryError.download }
            result.append(byte)
        }
        return result
        #endif
    }

    private final class HTTPSRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let address = request.url?.absoluteString, (try? EmbyIconLibraryClient.url(address)) != nil else {
                completionHandler(nil); return
            }
            completionHandler(request)
        }
    }
}
