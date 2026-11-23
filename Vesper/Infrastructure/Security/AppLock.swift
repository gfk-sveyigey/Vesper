import Combine
import Foundation
import LocalAuthentication
import SwiftUI
import Security
import UIKit

@MainActor
final class AppLock: ObservableObject {
    enum AuthenticationPurpose: String, Identifiable {
        var id: String { rawValue }
        case appUnlock
        case settingsAccess
        case sourcePrivacy
        case createPassword
        case resetPassword
        case disableProtection
    }

    enum BiometricType: Equatable {
        case faceID, touchID, none
        var title: String {
            switch self {
            case .faceID: VesperLocalization.string("面容 ID")
            case .touchID: VesperLocalization.string("触控 ID")
            case .none: VesperLocalization.string("生物识别")
            }
        }
        var symbol: String {
            switch self {
            case .faceID: "faceid"
            case .touchID: "touchid"
            case .none: "lock"
            }
        }
    }

    enum BiometricResult {
        case success, failure, passwordFallback
    }

    static let shared = AppLock()
    static let enabledKey = "appLock.enabled"
    static let biometricEnabledKey = "appLock.biometricEnabled"
    static let biometricPriorityKey = "appLock.biometricPriority"
    static let scopeKey = "appLock.scope"
    static let timeoutKey = "appLock.timeout"
    static let blurKey = "appLock.backgroundBlur"

    @Published private(set) var isLocked = false
    @Published private(set) var lastBackgroundDate: Date?
    @Published var authenticationRequest: AuthenticationPurpose?
    @Published private(set) var authenticationRequestID = UUID()
    @Published var settingsAuthorized = false
    private let passwordService = "com.aholic.vesper.app-lock"
    private var isActive = false
    private var didInitializeLifecycle = false
    var settingsVisibleProvider: (() -> Bool)?
    var isSettingsVisible: Bool { settingsVisibleProvider?() ?? false }
    private var authenticationCompletion: (() -> Void)?
    private var automaticBiometricAttemptRequestID: UUID?
    private(set) var isBiometricAuthenticationInProgress = false

    private init() {
        // Establish the gate before SwiftUI renders its first frame.
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.enabledKey), !Self.isSystemAuthenticationEnabled {
            let scope = defaults.string(forKey: Self.scopeKey) ?? "launch"
            if scope == "launch" || scope == "both" {
                isLocked = true
                authenticationRequest = .appUnlock
            }
        }
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var shouldBlurInBackground: Bool {
        UserDefaults.standard.object(forKey: Self.blurKey) as? Bool ?? true
    }
    var protectsSources: Bool {
        isEnabled && ["source", "both"].contains(UserDefaults.standard.string(forKey: Self.scopeKey) ?? "launch")
    }

    private static var isSystemAuthenticationEnabled: Bool {
        guard #available(iOS 18.0, *) else { return false }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.systemProtectionManager?.isUserAuthenticationEnabled == true }
    }

    var biometricType: BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // A biometric lockout is temporary. Keep the enrolled modality
            // visible/configurable; the App PIN fallback does not clear the
            // device's biometric lockout state.
            if let error = error as? LAError, error.code == .biometryLockout {
                return Self.biometricType(for: context.biometryType)
            }
            return .none
        }
        return Self.biometricType(for: context.biometryType)
    }

    private static func biometricType(for type: LABiometryType) -> BiometricType {
        switch type {
        case .faceID: .faceID
        case .touchID: .touchID
        default: .none
        }
    }

    func activate() {
        isActive = true
        isLocked = false
        lastBackgroundDate = nil
    }

    func activateIfNeeded() {
        guard isEnabled, !isActive else { return }
        isActive = true
        let scope = UserDefaults.standard.string(forKey: Self.scopeKey) ?? "launch"
        if scope != "source" { requestAuthentication(.appUnlock) }
    }

    func requestAuthentication(_ purpose: AuthenticationPurpose, completion: (() -> Void)? = nil) {
        guard isEnabled || [.createPassword, .resetPassword, .disableProtection].contains(purpose) else { return }
        if authenticationRequest == purpose {
            authenticationCompletion = completion
            return
        }
        if purpose == .appUnlock { settingsAuthorized = false }
        authenticationCompletion = completion
        authenticationRequest = purpose
        authenticationRequestID = UUID()
        if purpose == .appUnlock { isLocked = true }
    }

    func claimAutomaticBiometricAttempt(for requestID: UUID) -> Bool {
        guard authenticationRequest != nil, authenticationRequestID == requestID,
              automaticBiometricAttemptRequestID != requestID else { return false }
        automaticBiometricAttemptRequestID = requestID
        return true
    }

    func cancelAuthentication() {
        guard authenticationRequest != .appUnlock else { return }
        authenticationRequest = nil
        authenticationCompletion = nil
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

    func authenticateBiometrically(reason: String = "解锁 Vesper") async -> BiometricResult {
        guard !isBiometricAuthenticationInProgress else { return .failure }
        let context = LAContext()
        context.localizedFallbackTitle = VesperLocalization.string("使用密码")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .failure }
        isBiometricAuthenticationInProgress = true
        defer { isBiometricAuthenticationInProgress = false }
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                            localizedReason: VesperLocalization.string(reason))
            return success ? .success : .failure
        } catch let error as LAError where error.code == .userFallback {
            return .passwordFallback
        } catch {
            return .failure
        }
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
            let isFirstActivation = !didInitializeLifecycle
            didInitializeLifecycle = true
            if Self.isSystemAuthenticationEnabled {
                if authenticationRequest == .appUnlock {
                    // The system only activates the scene after its own
                    // authentication challenge has succeeded.
                    didUnlock()
                } else if authenticationRequest == nil {
                    // The operating system is the app-wide lock for this scene.
                    isActive = true
                    isLocked = false
                    lastBackgroundDate = nil
                }
                return
            }
            // Biometric UI can cause lifecycle callbacks while the same
            // authentication request is still being presented. Keep that
            // request alive instead of treating the callback as a new unlock.
            if authenticationRequest != nil {
                isActive = true
                lastBackgroundDate = nil
                return
            }
            if isFirstActivation {
                isActive = true
                // init() already establishes the cold-start gate. An active
                // callback must not create a second request after it succeeds.
                lastBackgroundDate = nil
                return
            }
            if !isActive {
                isActive = true
                let scope = UserDefaults.standard.string(forKey: Self.scopeKey) ?? "launch"
                isLocked = scope == "launch" || scope == "both"
                if isLocked { requestAuthentication(.appUnlock) }
                return
            }
            let scope = UserDefaults.standard.string(forKey: Self.scopeKey) ?? "launch"
            let seconds = UserDefaults.standard.double(forKey: Self.timeoutKey)
            guard let backgroundDate = lastBackgroundDate else { return }
            let withinGrace = Date().timeIntervalSince(backgroundDate) < seconds
            let requiresLock = scope == "launch" || scope == "both"
            let requiresSettingsAuth = isEnabled && isSettingsVisible && !withinGrace
            isLocked = requiresLock && !withinGrace
            if isLocked { requestAuthentication(.appUnlock) }
            else if requiresSettingsAuth { requestAuthentication(.settingsAccess) }
            lastBackgroundDate = nil
        default: break
        }
    }

    func didUnlock() {
        didInitializeLifecycle = true
        isActive = true
        isLocked = false
        authenticationRequest = nil
        authenticationRequestID = UUID()
        lastBackgroundDate = nil
    }

    func didAuthenticate(_ purpose: AuthenticationPurpose) {
        let completion = authenticationCompletion
        authenticationCompletion = nil
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if purpose == .appUnlock {
                didUnlock()
            } else if authenticationRequest == purpose {
                authenticationRequest = nil
                authenticationRequestID = UUID()
            }
        }
        if purpose == .settingsAccess { settingsAuthorized = true }
        if purpose == .disableProtection { settingsAuthorized = false }
        completion?()
    }

    func revokeSettingsAuthorization() { settingsAuthorized = false }

    func setBackgroundBlur(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.blurKey)
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

/// Window-level shielding also covers sheets and the full-screen player in app-switcher snapshots.
struct AppPrivacyBlurHost: UIViewRepresentable {
    func makeUIView(context: Context) -> PrivacyBlurObserverView { PrivacyBlurObserverView(frame: .zero) }
    func updateUIView(_ uiView: PrivacyBlurObserverView, context: Context) {}

    final class PrivacyBlurObserverView: UIView {
        private var shield: UIVisualEffectView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            NotificationCenter.default.addObserver(self, selector: #selector(obscure),
                name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(reveal),
                name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func obscure() {
            guard AppLock.shared.isEnabled, AppLock.shared.shouldBlurInBackground,
                  !AppLock.shared.isBiometricAuthenticationInProgress,
                  let window, shield == nil else { return }
            if #available(iOS 18.0, *),
               window.windowScene?.systemProtectionManager?.isUserAuthenticationEnabled == true {
                return
            }
            let style: UIBlurEffect.Style = {
                switch traitCollection.userInterfaceStyle {
                case .dark: return .systemMaterialDark
                case .light: return .systemMaterialLight
                default: return .systemMaterial
                }
            }()
            let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
            view.frame = window.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            window.addSubview(view)
            shield = view
            window.layoutIfNeeded()
        }

        @objc private func reveal() {
            shield?.removeFromSuperview()
            shield = nil
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { reveal() }
        }
    }
}
