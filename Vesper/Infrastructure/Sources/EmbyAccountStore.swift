import Foundation
import Security

private struct EmbyAccount: Codable {
    var token: String?
    var userID: String?
    var deviceID: String
    var customHeaders: [String: String]
}

@MainActor
final class EmbyAccountStore {
    static let shared = EmbyAccountStore()
    private init() {}

    func authenticate(source: MediaSource, username: String, password: String) async throws -> EmbyAuthentication {
        guard let config = source.emby else { throw EmbyError.invalidAddress }
        let client = try EmbyAPIClient(configuration: config, token: nil, deviceID: deviceID())
        let publicInfo = try await client.get("System/Info/Public")
        guard let serverID = publicInfo["Id"] as? String else { throw EmbyError.invalidResponse }
        let serverName = (publicInfo["ServerName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if username.isEmpty && password.isEmpty {
            try save(EmbyAccount(token: nil, userID: nil, deviceID: deviceID(), customHeaders: config.customHeaders), sourceID: source.id)
            return EmbyAuthentication(serverID: serverID, userID: nil, serverName: serverName?.isEmpty == false ? serverName : nil)
        }
        let payload: [String: Any] = ["Username": username, "Pw": password]
        let result = try await client.send("Users/AuthenticateByName", method: "POST", body: EmbyJSON(payload))
        guard let token = result["AccessToken"] as? String,
              let user = result["User"] as? [String: Any],
              let userID = user["Id"] as? String else { throw EmbyError.authentication }
        try save(EmbyAccount(token: token, userID: userID, deviceID: deviceID(), customHeaders: config.customHeaders), sourceID: source.id)
        return EmbyAuthentication(serverID: serverID, userID: userID, serverName: serverName?.isEmpty == false ? serverName : nil)
    }

    func client(for source: MediaSource) throws -> EmbyAPIClient {
        guard var config = source.emby, let account = account(sourceID: source.id) else { throw EmbyError.missingAccount }
        config.customHeaders = account.customHeaders
        config.userID = account.userID
        return try EmbyAPIClient(configuration: config, token: account.token, deviceID: account.deviceID)
    }

    /// Check identity without account credentials before sending a token to this route.
    func verifyConnection(for source: MediaSource) async throws {
        guard var configuration = source.emby, let expectedServerID = configuration.serverID,
              !expectedServerID.isEmpty, let account = account(sourceID: source.id) else {
            throw EmbyError.missingAccount
        }
        configuration.customHeaders = [:]
        let publicClient = try EmbyAPIClient(configuration: configuration, token: nil, deviceID: "route-validation")
        let info = try await publicClient.get("System/Info/Public")
        guard info["Id"] as? String == expectedServerID else { throw EmbyError.invalidResponse }
        try Task.checkCancellation()
        // A saved guest account has no login session to validate.
        guard let userID = account.userID, !userID.isEmpty else {
            guard configuration.userID == nil, configuration.username.isEmpty else { throw EmbyError.authentication }
            return
        }
        guard let token = account.token, !token.isEmpty, configuration.userID == userID else {
            throw EmbyError.authentication
        }
        configuration.customHeaders = account.customHeaders
        configuration.userID = userID
        let client = try EmbyAPIClient(configuration: configuration, token: token, deviceID: account.deviceID)
        let user = try await client.get("Users/\(userID)")
        guard user["Id"] as? String == userID else { throw EmbyError.authentication }
    }

    func customHeaders(sourceID: UUID) -> [String: String] { account(sourceID: sourceID)?.customHeaders ?? [:] }

    func updateCustomHeaders(_ headers: [String: String], sourceID: UUID) throws {
        guard var account = account(sourceID: sourceID) else { throw EmbyError.missingAccount }
        account.customHeaders = headers
        try save(account, sourceID: sourceID)
    }

    func logout(source: MediaSource) {
        guard let client = try? client(for: source) else { remove(sourceID: source.id); return }
        remove(sourceID: source.id)
        Task { _ = try? await client.send("Sessions/Logout", method: "POST") }
    }

    func remove(sourceID: UUID) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.aholic.vesper.emby",
                                   kSecAttrAccount as String: sourceID.uuidString]
        SecItemDelete(query as CFDictionary)
    }

    private func account(sourceID: UUID) -> EmbyAccount? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.aholic.vesper.emby",
                                   kSecAttrAccount as String: sourceID.uuidString,
                                   kSecReturnData as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(EmbyAccount.self, from: data)
    }

    private func save(_ account: EmbyAccount, sourceID: UUID) throws {
        guard let data = try? JSONEncoder().encode(account) else { throw EmbyError.missingAccount }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.aholic.vesper.emby",
                                   kSecAttrAccount as String: sourceID.uuidString]
        let values: [String: Any] = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                    kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw EmbyError.missingAccount
            }
        } else if status != errSecSuccess { throw EmbyError.missingAccount }
    }

    private func deviceID() -> String {
        let key = "emby.device.id"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}

