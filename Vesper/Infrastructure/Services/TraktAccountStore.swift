import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import UIKit

/// Development registration. Production needs its own client ID and verified HTTPS callback.
enum TraktConfiguration {
    static let clientID = "VtIonDK3n2fUteHwdrfUNqsBh5y2gwtRddv_WFM1DnM"
    static let redirectURI = "vesper://trakt/callback"
}

@MainActor
final class TraktAccountStore: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = TraktAccountStore()
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published var errorMessage: String?
    private let network = URLSession(configuration: .ephemeral)
    private var session: ASWebAuthenticationSession?
    private var exchange: Task<Void, Never>?
    private var attempt = UUID()

    private typealias Token = TraktToken
    private var token: Token?
    private var refreshing: Task<Token, Error>?
    private var refreshID = UUID()
    private(set) var accountRevision = UUID()

    private enum Failure: Error { case random, callback, network, storage, disconnected }
    private struct HTTPFailure: Error { let status: Int; let retryAfter: TimeInterval? }
    private let keychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.aholic.vesper.trakt",
        kSecAttrAccount as String: "account"
    ]

    private override init() {
        super.init()
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
           let data = value as? Data, let saved = try? JSONDecoder().decode(Token.self, from: data),
           saved.isValid {
            token = saved
            isConnected = true
        }
    }

    func connect() {
        guard !isConnecting else { return }
        errorMessage = nil
        do {
            let verifier = try randomValue()
            let state = try randomValue()
            let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            var components = URLComponents(string: "https://auth.trakt.tv/oauth/authorize")!
            components.queryItems = [
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "client_id", value: TraktConfiguration.clientID),
                URLQueryItem(name: "redirect_uri", value: TraktConfiguration.redirectURI),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256")
            ]
            guard let url = components.url else { throw Failure.callback }
            let id = UUID()
            attempt = id
            let web = ASWebAuthenticationSession(url: url, callbackURLScheme: "vesper") { [weak self] url, error in
                Task { @MainActor [weak self] in
                    guard let self, self.attempt == id else { return }
                    self.session = nil
                    if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        self.isConnecting = false
                        return
                    }
                    guard error == nil, let url,
                          url.scheme == "vesper", url.host == "trakt", url.path == "/callback",
                          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                          items.filter({ $0.name == "state" }).count == 1,
                          items.first(where: { $0.name == "state" })?.value == state,
                          !items.contains(where: { $0.name == "error" }),
                          items.filter({ $0.name == "code" }).count == 1,
                          let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                        self.fail()
                        return
                    }
                    self.exchange = Task { [weak self] in
                        guard let self else { return }
                        do {
                            let token = try await self.exchangeCode(code, verifier: verifier)
                            try Task.checkCancellation()
                            guard self.attempt == id else { return }
                            try self.save(token)
                            self.token = token
                            self.accountRevision = UUID()
                            self.isConnected = true
                            self.isConnecting = false
                            self.exchange = nil
                        } catch {
                            guard self.attempt == id else { return }
                            self.fail()
                        }
                    }
                }
            }
            web.presentationContextProvider = self
            session = web
            isConnecting = true
            if !web.start() { session = nil; fail() }
        } catch { fail() }
    }

    func disconnect() {
        attempt = UUID()
        session?.cancel()
        session = nil
        exchange?.cancel()
        exchange = nil
        refreshing?.cancel()
        refreshing = nil
        refreshID = UUID()
        token = nil
        accountRevision = UUID()
        isConnected = false
        isConnecting = false
        errorMessage = nil
        let status = SecItemDelete(keychainQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { fail() }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private func fail() {
        isConnecting = false
        exchange = nil
        errorMessage = String(localized: "Trakt 连接失败，请检查网络和应用回调配置后重试。")
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> Token {
        try await requestToken([
            "code": code, "client_id": TraktConfiguration.clientID,
            "redirect_uri": TraktConfiguration.redirectURI,
            "grant_type": "authorization_code", "code_verifier": verifier
        ])
    }

    private func requestToken(_ fields: [String: String]) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://auth.trakt.tv/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(fields)
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.network }
        guard http.statusCode == 200 else { throw HTTPFailure(status: http.statusCode, retryAfter: nil) }
        let token = try JSONDecoder().decode(Token.self, from: data)
        guard token.isValid else { throw Failure.network }
        return token
    }

    func accountOverview() async throws -> TraktAccountOverview {
        let revision = accountRevision
        let settings = try await api("users/settings", revision: revision)
        let user = try JSONDecoder().decode(TraktAccountSettings.self, from: settings).user
        // Use the authenticated alias rather than interpolating a user-controlled name.
        let data = try await api("users/me/stats", revision: revision)
        try Task.checkCancellation()
        guard accountRevision == revision, isConnected else { throw Failure.disconnected }
        // Trakt returns 204 when precomputed statistics are unavailable.
        let statistics = data.isEmpty ? nil : try JSONDecoder().decode(TraktAccountStatistics.self, from: data)
        return TraktAccountOverview(user: user, statistics: statistics)
    }

    /// Coalesce all callers. The rotating refresh token is persisted before any waiter resumes.
    private func accessToken(revision: UUID, rejectedToken: String? = nil) async throws -> String {
        guard accountRevision == revision, let saved = token else { throw Failure.disconnected }
        if let refreshing { return (try await refreshing.value).access_token }
        if !saved.needsRefresh(at: Date()), rejectedToken != saved.access_token { return saved.access_token }
        let id = UUID()
        refreshID = id
        let task = Task { @MainActor [self] in
            do {
                let replacement = try await requestToken([
                    "grant_type": "refresh_token", "refresh_token": saved.refresh_token,
                    "client_id": TraktConfiguration.clientID,
                    "redirect_uri": TraktConfiguration.redirectURI
                ])
                try Task.checkCancellation()
                guard accountRevision == revision else { throw Failure.disconnected }
                do { try save(replacement) }
                catch {
                    // A single-use refresh token was consumed; do not retry the obsolete token.
                    disconnect()
                    throw Failure.storage
                }
                token = replacement
                return replacement
            } catch let error as HTTPFailure {
                if accountRevision == revision, error.status == 400 || error.status == 401 {
                    disconnect()
                }
                throw error
            }
        }
        refreshing = task
        defer { if refreshID == id { refreshing = nil } }
        return (try await task.value).access_token
    }

    /// One refresh/replay on 401. The caller owns pacing and rate-limit handling.
    func api(_ path: String, method: String = "GET", body: Data? = nil, revision: UUID) async throws -> Data {
        let first = try await accessToken(revision: revision)
        for retry in 0...1 {
            let credential: String
            if retry == 0 { credential = first }
            else { credential = try await accessToken(revision: revision, rejectedToken: first) }
            try Task.checkCancellation()
            guard accountRevision == revision, isConnected else { throw Failure.disconnected }
            var request = URLRequest(url: URL(string: "https://api.trakt.tv/" + path)!)
            request.httpMethod = method
            request.timeoutInterval = 20
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2", forHTTPHeaderField: "trakt-api-version")
            request.setValue(TraktConfiguration.clientID, forHTTPHeaderField: "trakt-api-key")
            request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
            let (data, response) = try await network.data(for: request)
            guard accountRevision == revision else { throw Failure.disconnected }
            guard let http = response as? HTTPURLResponse else { throw Failure.network }
            if http.statusCode == 401 {
                if retry == 0 { continue }
                disconnect()
            }
            // Trakt returns 409 for a recently recorded scrobble; it is already recorded.
            if (200..<300).contains(http.statusCode) || (method == "POST" && http.statusCode == 409) { return data }
            throw HTTPFailure(status: http.statusCode,
                              retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        throw Failure.disconnected
    }

    func diagnostic(for error: Error) -> String {
        if let failure = error as? HTTPFailure { return "HTTP \(failure.status)" }
        if let failure = error as? URLError { return "network \(failure.code.rawValue)" }
        return "credential-or-response"
    }

    func retryDelay(for error: Error) -> TimeInterval? {
        guard let failure = error as? HTTPFailure, failure.status == 429 else { return nil }
        return max(1, failure.retryAfter ?? 5)
    }

    private func save(_ token: Token) throws {
        let data = try JSONEncoder().encode(token)
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(keychainQuery as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(keychainQuery.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw Failure.storage
            }
        } else if status != errSecSuccess { throw Failure.storage }
    }

    private func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.random }
        return base64URL(Data(bytes))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// Foundation-only values keep media matching and lifecycle policy testable without a player.
struct TraktAccountSettings: Decodable, Sendable {
    let user: TraktAccountUser
}

struct TraktAccountUser: Decodable, Sendable {
    struct Images: Decodable, Sendable {
        struct Avatar: Decodable, Sendable { let full: String? }
        let avatar: Avatar?
    }
    let username: String
    let name: String?
    let vip: Bool?
    let vip_ep: Bool?
    let images: Images?
    var displayName: String {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? username : value
    }
    var isVIP: Bool { vip == true || vip_ep == true }
    var avatarURL: URL? {
        guard let full = images?.avatar?.full, let url = URL(string: full),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

struct TraktAccountStatistics: Decodable, Sendable {
    struct Media: Decodable, Sendable {
        let watched: Int
        let minutes: Int?
    }
    let movies: Media
    let shows: Media
    let episodes: Media
    var watchedMinutes: Int { max(0, movies.minutes ?? 0) + max(0, episodes.minutes ?? 0) }
}

struct TraktAccountOverview: Sendable {
    let user: TraktAccountUser
    let statistics: TraktAccountStatistics?
}

struct TraktToken: Codable, Sendable {
    let access_token: String
    let refresh_token: String
    let created_at: Double
    let expires_in: Double
    var isValid: Bool {
        !access_token.isEmpty && !refresh_token.isEmpty && created_at.isFinite &&
        expires_in.isFinite && expires_in > 0
    }
    func needsRefresh(at date: Date) -> Bool {
        date.timeIntervalSince1970 >= created_at + expires_in - 60
    }
}

struct TraktMediaIdentity: Sendable, Equatable {
    let kind: String
    let ids: [String: String]
    var season: Int? = nil
    var episode: Int? = nil

    static func supportedIDs(_ providers: [String: String]) -> [String: String] {
        var ids: [String: String] = [:]
        for (key, value) in providers {
            let key = key.lowercased()
            if ["trakt", "tmdb", "tvdb"].contains(key),
               let number = Int(value), number > 0 { ids[key] = String(number) }
            if key == "imdb", value.hasPrefix("tt"),
               value.dropFirst(2).isEmpty == false,
               value.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) }) { ids[key] = value }
        }
        return ids
    }

    var jsonIDs: [String: Any] {
        ids.reduce(into: [:]) { result, entry in
            if entry.key == "imdb" { result[entry.key] = entry.value }
            else if let number = Int(entry.value) { result[entry.key] = number }
        }
    }
}

struct TraktScrobbleState {
    enum Action: String { case start, pause, stop }
    private(set) var started = false
    private(set) var playing = false
    private(set) var stopped = false

    mutating func update(playing: Bool, ended: Bool) -> Action? {
        guard !stopped else { return nil }
        if ended { return finish() }
        if playing {
            guard !self.playing else { return nil }
            started = true
            self.playing = true
            return .start
        }
        guard started, self.playing else { return nil }
        self.playing = false
        return .pause
    }

    mutating func finish() -> Action? {
        guard started, !stopped else { return nil }
        stopped = true
        playing = false
        return .stop
    }

    static func progress(position: Double, duration: Double) -> Double? {
        guard position.isFinite, duration.isFinite, duration > 0 else { return nil }
        return min(100, max(0, position / duration * 100))
    }
}

/// Shared by both engines. Loading, seeking and decoder replacement are not playback events.
@MainActor
final class TraktPlaybackReporter {
    private let account: TraktAccountStore
    private var mediaID: MediaID?
    private var revision: UUID?
    private var identity: Task<TraktMediaIdentity?, Never>?
    private var state = TraktScrobbleState()
    private var position: Double = 0
    private var duration: Double = 0
    private let sender = TraktScrobbleSender()

    init(account: TraktAccountStore = .shared) { self.account = account }

    func update(item: MediaItem?, source: MediaSource?, position: Double, duration: Double,
                playing: Bool, ended: Bool, ready: Bool) {
        guard account.isConnected, let item, let source, source.kind == .emby,
              source.id == item.id.sourceID else { reset(); return }
        if mediaID != item.id || revision != account.accountRevision {
            finish()
            mediaID = item.id
            revision = account.accountRevision
            state = TraktScrobbleState()
            identity = Task {
                do { return try await EmbyRepository.shared.traktIdentity(for: item, source: source) }
                catch {
                    Self.log("媒体标识查询失败，跳过本次上报")
                    return nil
                }
            }
        }
        guard ready, let progress = TraktScrobbleState.progress(position: position, duration: duration) else { return }
        self.position = position
        self.duration = duration
        if let action = state.update(playing: playing, ended: ended) { enqueue(action, progress: progress) }
    }

    func finish() {
        if let action = state.finish(),
           let progress = TraktScrobbleState.progress(position: position, duration: duration) {
            enqueue(action, progress: progress)
        }
        reset()
    }

    private func reset() {
        mediaID = nil
        revision = nil
        identity = nil
        state = TraktScrobbleState()
        position = 0
        duration = 0
    }

    private func enqueue(_ action: TraktScrobbleState.Action, progress: Double) {
        guard let identity, let revision else { return }
        sender.enqueue(action, progress: progress, identity: identity, revision: revision, account: account)
    }

    static func log(_ message: String) {
        AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [Trakt] \(message)")
    }
}

/// Preserve start/pause/stop order across track changes without blocking the playback actor.
@MainActor
private final class TraktScrobbleSender {
    private var tail: Task<Void, Never>?
    private var queued = 0
    private var nextWrite = Date.distantPast
    private var cachedIdentity: TraktMediaIdentity?
    private var cachedPayload: [String: Any]?
    private var cachedRevision: UUID?


    func enqueue(_ action: TraktScrobbleState.Action, progress: Double,
                 identity: Task<TraktMediaIdentity?, Never>, revision: UUID, account: TraktAccountStore) {
        guard queued < 100 else { TraktPlaybackReporter.log("上报队列已满，跳过事件"); return }
        queued += 1
        let previous = tail
        tail = Task { [self] in
            await previous?.value
            defer { queued -= 1; if queued == 0 { tail = nil } }
            guard account.isConnected, account.accountRevision == revision,
                  let media = await identity.value else { return }
            do {
                let payload = try await payload(media, account: account, revision: revision)
                var body = payload
                body["progress"] = progress
                let data = try JSONSerialization.data(withJSONObject: body)
                for attempt in 0...2 {
                    guard account.isConnected, account.accountRevision == revision else { return }
                    let wait = nextWrite.timeIntervalSinceNow
                    if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                    do {
                        nextWrite = Date().addingTimeInterval(1.1)
                        _ = try await account.api("scrobble/" + action.rawValue, method: "POST", body: data, revision: revision)
                        TraktPlaybackReporter.log("播放事件同步成功：\(action.rawValue)")
                        return
                    } catch {
                        // A 429 was rejected before execution. Do not replay ambiguous POST failures.
                        guard attempt < 2, let delay = account.retryDelay(for: error) else { throw error }
                        nextWrite = Date().addingTimeInterval(delay)
                    }
                }
            } catch {
                TraktPlaybackReporter.log("播放事件同步失败：\(action.rawValue)，本地播放继续（\(account.diagnostic(for: error))）")
            }
        }
    }

    private func payload(_ media: TraktMediaIdentity, account: TraktAccountStore,
                         revision: UUID) async throws -> [String: Any] {
        if cachedIdentity == media, cachedRevision == revision, let cachedPayload { return cachedPayload }
        let result = try await resolvePayload(media, account: account, revision: revision)
        cachedIdentity = media
        cachedRevision = revision
        cachedPayload = result
        return result
    }

    private func resolvePayload(_ media: TraktMediaIdentity, account: TraktAccountStore,
                                revision: UUID) async throws -> [String: Any] {
        guard let season = media.season, let episode = media.episode else {
            return [media.kind: ["ids": media.jsonIDs]]
        }
        // Series provider IDs must never be sent as episode IDs.
        guard let key = ["trakt", "imdb", "tmdb", "tvdb"].first(where: { media.ids[$0] != nil }),
              let id = media.ids[key] else { throw URLError(.cannotParseResponse) }
        let lookup = try await account.api("search/\(key)/\(id)?type=show", revision: revision)
        let rows = try JSONSerialization.jsonObject(with: lookup) as? [[String: Any]]
        guard let row = rows?.first(where: { $0["type"] as? String == "show" }),
              let show = row["show"] as? [String: Any],
              let ids = show["ids"] as? [String: Any],
              let trakt = ids["trakt"] as? Int else { throw URLError(.cannotParseResponse) }
        let detail = try await account.api("shows/\(trakt)/seasons/\(season)/episodes/\(episode)", revision: revision)
        guard let object = try JSONSerialization.jsonObject(with: detail) as? [String: Any],
              let ids = object["ids"] as? [String: Any], ids["trakt"] as? Int != nil else {
            throw URLError(.cannotParseResponse)
        }
        return ["episode": ["ids": ids]]
    }
}

enum EmbyProgressSource: String, CaseIterable, Identifiable {
    case trakt, server, local
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .trakt: "Trakt 记录进度"
        case .server: "服务器记录进度"
        case .local: "本地记录进度"
        }
    }
}

enum EmbyProgressPriority {
    static let key = "emby.progressPriority"
    static let defaultOrder = "trakt,server,local"
    static func order(_ raw: String) -> [EmbyProgressSource] {
        var seen = Set<EmbyProgressSource>()
        let saved = raw.split(separator: ",").compactMap { EmbyProgressSource(rawValue: String($0)) }
        return (saved + EmbyProgressSource.allCases).filter { seen.insert($0).inserted }
    }
    static var sources: [EmbyProgressSource] {
        order(UserDefaults.standard.string(forKey: key) ?? defaultOrder)
    }
    static func validPosition(_ value: Double?, duration: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        if let duration, duration.isFinite, duration > 0, value >= duration - min(2, duration * 0.05) { return 0 }
        return value
    }
}

extension TraktAccountStore {
    /// Fetch paused playback progress, not watched-history completion flags.
    func resumePosition(for item: MediaItem, source: MediaSource, duration: Double) async -> Double? {
        guard isConnected, duration.isFinite, duration > 0 else { return nil }
        let revision = accountRevision
        do {
            guard let identity = try await EmbyRepository.shared.traktIdentity(for: item, source: source) else { return nil }
            let category = identity.kind == "movie" ? "movies" : "episodes"
            try Task.checkCancellation()
            // Without pagination parameters Trakt returns the complete paused-progress set.
            let data = try await api("sync/playback/\(category)", revision: revision)
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            for row in rows {
                guard let media = row[identity.kind] as? [String: Any] else { continue }
                let matches: Bool
                if let season = identity.season, let episode = identity.episode {
                    let show = row["show"] as? [String: Any]
                    matches = TraktResumeProgress.matches(identity.ids, responseIDs: show?["ids"] as? [String: Any] ?? [:])
                        && media["season"] as? Int == season && media["number"] as? Int == episode
                } else {
                    matches = TraktResumeProgress.matches(identity.ids, responseIDs: media["ids"] as? [String: Any] ?? [:])
                }
                if matches, let position = TraktResumeProgress.seconds(
                    percent: (row["progress"] as? NSNumber)?.doubleValue, duration: duration
                ) { return position }
            }
        } catch {
            TraktPlaybackReporter.log("续播进度读取失败，尝试下一优先来源")
        }
        return nil
    }
}

enum TraktResumeProgress {
    static func matches(_ expected: [String: String], responseIDs: [String: Any]) -> Bool {
        expected.contains { key, value in
            if let actual = responseIDs[key] as? String { return actual == value }
            if let actual = responseIDs[key] as? NSNumber { return actual.stringValue == value }
            return false
        }
    }
    static func seconds(percent: Double?, duration: Double) -> Double? {
        guard let percent, percent.isFinite, (0...100).contains(percent), duration.isFinite, duration > 0 else { return nil }
        return EmbyProgressPriority.validPosition(duration * percent / 100, duration: duration)
    }
}
