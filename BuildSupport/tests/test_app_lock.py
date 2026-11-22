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
        self.assertIn('Text("App 启动和媒体来源").tag("both")', settings)
        self.assertIn("appLock.sceneChanged(phase)", navigation)
        self.assertNotIn("appLock.sourceChanged()", navigation)
        self.assertIn("AppPrivacyBlurHost()", navigation)
        auth_overlay = navigation.split('if appLock.authenticationRequest != nil', 1)[1].split('}', 1)[0]
        self.assertNotIn('.transition(.opacity)', auth_overlay)
        self.assertIn("isSettingsVisible && !withinGrace", lock)
        self.assertIn("appLock.requestAuthentication(.resetPassword)", settings)
        self.assertIn('case .resetPassword: "输入旧密码以重置"', settings)
        self.assertIn("if failures >= 2 { showPassword = true }", settings)
        self.assertIn("!(biometricPriority && failures == 0)", settings)
        self.assertIn("!appLock.isBiometricAuthenticationInProgress", settings)
        self.assertIn("automaticAttemptPurpose != appLock.authenticationRequest", settings)
        self.assertIn("appLock.authenticationRequest != nil, !playback.isPresented", navigation)
        self.assertIn("didBecomeActiveNotification", lock)
        self.assertIn("willResignActiveNotification", lock)
        self.assertIn("// Establish the gate before SwiftUI renders its first frame.", lock)
        self.assertIn("!AppLock.shared.isBiometricAuthenticationInProgress", lock)
        self.assertIn(".appLockBiometricAttemptFinished", lock)
        self.assertIn("func biometricAttemptFinished()", lock)
        self.assertIn("UIApplication.shared.applicationState != .active", lock)
        self.assertIn("transaction.disablesAnimations = true", lock)
        self.assertIn(".transition(.identity)", navigation)
        self.assertIn("E10000000000000000000014", project)
        self.assertIn("NSFaceIDUsageDescription", (ROOT / "Info.plist").read_text())


if __name__ == "__main__":
    unittest.main()
