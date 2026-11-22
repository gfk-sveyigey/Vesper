from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AppLockTests(unittest.TestCase):
    def test_secure_store_and_authentication_are_wired(self):
        lock = (ROOT / "Vesper/Infrastructure/Security/AppLock.swift").read_text()
        settings = (ROOT / "Vesper/Features/Settings/SettingsView.swift").read_text()
        navigation = (ROOT / "Vesper/Features/Navigation/AppNavigationView.swift").read_text()
        project = (ROOT / "Vesper.xcodeproj/project.pbxproj").read_text()
        self.assertIn("SecItemAdd", lock)
        self.assertIn("evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics", lock)
        self.assertIn("error.code == .userFallback", lock)
        self.assertIn("return .passwordFallback", lock)
        self.assertNotIn("appLockBiometricAttemptFinished", lock)
        self.assertIn("case .passwordFallback:\n            showPassword = true", settings)
        self.assertIn('Text("App 启动和媒体来源").tag("both")', settings)
        self.assertIn("appLock.sceneChanged(phase)", navigation)
        self.assertNotIn("appLock.sourceChanged()", navigation)
        self.assertIn("AppPrivacyBlurHost()", navigation)
        auth_overlay = navigation.split('if appLock.authenticationRequest != nil', 1)[1].split('}', 1)[0]
        self.assertNotIn('.transition(.opacity)', auth_overlay)
        self.assertIn("isSettingsVisible && !withinGrace", lock)
        first_active = lock.split("guard didInitializeLifecycle else", 1)[1].split("if !isActive", 1)[0]
        self.assertIn("lastBackgroundDate = nil", first_active)
        self.assertIn("appLock.requestAuthentication(.resetPassword)", settings)
        self.assertIn("claimAutomaticBiometricAttempt(for: requestID)", settings)
        self.assertIn("@Published private(set) var authenticationRequestID", lock)
        self.assertIn("if authenticationRequest == purpose", lock)
        self.assertIn("if authenticationRequest != nil {", lock)
        self.assertIn('case .resetPassword: "输入旧密码以重置"', settings)
        self.assertIn("if failures >= 2 { showPassword = true }", settings)
        self.assertIn("!(biometricPriority && failures == 0)", settings)
        self.assertIn("!appLock.isBiometricAuthenticationInProgress", settings)
        self.assertIn(".task(id: appLock.authenticationRequestID)", settings)
        self.assertNotIn("automaticAttemptPurpose", settings)
        self.assertIn("appLock.authenticationRequest != nil, !playback.isPresented", navigation)
        self.assertIn("didBecomeActiveNotification", lock)
        self.assertIn("willResignActiveNotification", lock)
        self.assertIn("// Establish the gate before SwiftUI renders its first frame.", lock)
        self.assertIn("!AppLock.shared.isBiometricAuthenticationInProgress", lock)
        self.assertIn("transaction.disablesAnimations = true", lock)
        self.assertIn(".transition(.identity)", navigation)
        self.assertIn("$0.disablesAnimations = true; $0.animation = nil", navigation)
        self.assertIn("E10000000000000000000014", project)
        self.assertIn("NSFaceIDUsageDescription", (ROOT / "Info.plist").read_text())


if __name__ == "__main__":
    unittest.main()
