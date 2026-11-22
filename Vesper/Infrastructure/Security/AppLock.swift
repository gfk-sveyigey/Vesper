import Combine
import Foundation
import LocalAuthentication
import SwiftUI
import Security

@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    static let enabledKey = "appLock.enabled"
    static let biometricEnabledKey = "appLock.biometricEnabled"
    static let biometricPriorityKey = "appLock.biometricPriority"
    static let scopeKey = "appLock.scope"
    static let timeoutKey = "appLock.timeout"
    static let blurKey = "appLock.backgroundBlur"

    @Published private(set) var isLocked = false
    @Published private(set) var lastBackgroundDate: Date?
    private let passwordService = "com.aholic.vesper.app-lock"
    private var isActive = false

    private init() {}

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var shouldBlurInBackground: Bool { UserDefaults.standard.bool(forKey: Self.blurKey) }

    func activate() {
        isActive = true
        isLocked = false
        lastBackgroundDate = nil
    }

    func activateIfNeeded() {
        guard isEnabled, !isActive else { return }
        isActive = true
        isLocked = true
    }

    func setPassword(_ password: String) throws {
        guard password.count == 6, password.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            throw LockError.invalidPassword
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: passwordService,
                                   kSecAttrAccount as String: "pin"]
        let value = password.data(using: .utf8)!
        let attributes: [String: Any] = [kSecValueData as String: value,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw LockError.keychain
            }
        } else if status != errSecSuccess { throw LockError.keychain }
    }

    func verify(_ password: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: passwordService,
                                   kSecAttrAccount as String: "pin",
                                   kSecReturnData as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let saved = String(data: data, encoding: .utf8) else { return false }
        return saved == password
    }

    func removePassword() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: passwordService,
                                   kSecAttrAccount as String: "pin"]
        SecItemDelete(query as CFDictionary)
    }

    func authenticateBiometrically() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = VesperLocalization.string("使用密码")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                     localizedReason: VesperLocalization.string("解锁 Vesper"))
        } catch { return false }
    }

    func sceneChanged(_ phase: ScenePhase) {
        guard isEnabled else {
            isActive = false
            isLocked = false
            lastBackgroundDate = nil
            return
        }
        switch phase {
        case .background:
            lastBackgroundDate = Date()
        case .active:
            if !isActive {
                isActive = true
                let scope = UserDefaults.standard.string(forKey: Self.scopeKey) ?? "launch"
                isLocked = scope == "launch" || scope == "both"
                return
            }
            let scope = UserDefaults.standard.string(forKey: Self.scopeKey) ?? "launch"
            let seconds = UserDefaults.standard.double(forKey: Self.timeoutKey)
            let requiresLock = scope == "launch" || scope == "both"
            guard let lastBackgroundDate else { return }
            let withinGrace = Date().timeIntervalSince(lastBackgroundDate) < seconds
            isLocked = requiresLock && !withinGrace
            lastBackgroundDate = nil
        default: break
        }
    }

    func didUnlock() {
        isActive = true
        isLocked = false
        lastBackgroundDate = nil
    }

    func setBackgroundBlur(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.blurKey)
    }

    func sourceChanged() {
        let scope = UserDefaults.standard.string(forKey: Self.scopeKey) ?? "launch"
        if isEnabled, isActive, scope == "source" || scope == "both" { isLocked = true }
    }

    enum LockError: LocalizedError {
        case invalidPassword, keychain
        var errorDescription: String? {
            switch self {
            case .invalidPassword: VesperLocalization.string("请输入六位数字密码。")
            case .keychain: VesperLocalization.string("无法安全保存密码。")
            }
        }
    }
}
