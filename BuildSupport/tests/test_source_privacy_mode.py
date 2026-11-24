from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SourcePrivacyModeTests(unittest.TestCase):
    def setUp(self):
        self.view = (ROOT / 'Vesper/Features/Sources/SourcesView.swift').read_text()
        self.library = (ROOT / 'Vesper/Infrastructure/Sources/SourceLibrary.swift').read_text()

    def test_existing_password_and_distinct_icons(self):
        self.assertIn('appLock.requestAuthentication(.sourcePrivacy)', self.view)
        self.assertNotIn('setPassword(', self.view)
        self.assertIn('isPrivacyModeEnabled ? "eye" : "eye.slash"', self.view)
        actions = self.view.split('} actions: {', 1)[1].split('.alert(item:', 1)[0]
        for action in ('togglePrivacyMode()', 'showingOrder = true', 'testRouteLatencies()', 'addMenu'):
            self.assertIn(action, actions)
        self.assertEqual(actions.count('.glassEffect('), 1)

    def test_protected_source_has_lock_next_to_name_without_moving_selection_checkmark(self):
        row = self.view.split('private struct SourceListRow<Actions: View>', 1)[1]
        self.assertIn('if library.isProtected(source) {\n                            Image(systemName: "lock.fill")', row)
        self.assertIn('.accessibilityLabel("受密码保护")', row)
        self.assertLess(row.index('Image(systemName: "lock.fill")'), row.index('if isSelected {'))

    def test_exit_stops_playback_independently_of_selected_source(self):
        toggle = self.view.split('private func togglePrivacyMode()', 1)[1].split('private var iconInset', 1)[0]
        self.assertIn('protectedSourceIDs.contains(item.id.sourceID)', toggle)
        self.assertLess(toggle.index('playback.stop()'), toggle.index('library.setPrivacyMode(false)'))
        exit_mode = self.library.split('func setPrivacyMode', 1)[1].split('func testProtected', 1)[0]
        self.assertIn('self.selectedID = visibleSources.first?.id', exit_mode)
        self.assertIn('embyHome = nil', exit_mode)
        self.assertIn('persist()', exit_mode)

    def test_visibility_and_latency_are_filtered(self):
        self.assertIn('sources.filter { !canUsePrivacyMode || isPrivacyModeEnabled || !isProtected($0) }', self.library)
        self.assertIn('guard canUsePrivacyMode else { return }', self.library)
        self.assertIn('for source in visibleSources where source.kind == .emby', self.library)
        self.assertIn('if canUsePrivacyMode, !isPrivacyModeEnabled,', self.library)
        self.assertIn('library.testProtectedRouteLatencies()', self.view)
        self.assertIn('ForEach(library.visibleSources)', self.view)
        media = (ROOT / 'Vesper/Features/Media/MediaView.swift').read_text()
        self.assertIn('ForEach(library.visibleSources)', media)

    def test_foreground_relocks_expired_source_privacy_before_restoring_playback(self):
        navigation = (ROOT / "Vesper/Features/Navigation/AppNavigationView.swift").read_text()
        lock = (ROOT / "Vesper/Infrastructure/Security/AppLock.swift").read_text()
        scene_change = navigation.split("private func handleScenePhaseChange", 1)[1].split(
            "private func stopProtectedSourcePlayback", 1
        )[0]
        self.assertLess(scene_change.index("updateAppLock(for: phase)"), scene_change.index("playback.handleScenePhase(phase)"))
        update_lock = scene_change.split("private func updateAppLock", 1)[1]
        self.assertIn("if phase == .active, appLock.protectsSources, library.isPrivacyModeEnabled,", update_lock)
        self.assertIn("appLock.backgroundGraceExpired", update_lock)
        self.assertLess(update_lock.index("stopProtectedSourcePlayback()"), update_lock.index("library.setPrivacyMode(false)"))
        self.assertLess(update_lock.index("library.setPrivacyMode(false)"), update_lock.index("appLock.sceneChanged(phase)"))
        grace = lock.split("var backgroundGraceExpired: Bool", 1)[1].split("private static var", 1)[0]
        self.assertIn("guard let lastBackgroundDate else { return false }", grace)
        self.assertIn("Self.timeoutKey", grace)
        self.assertIn("timeIntervalSince(lastBackgroundDate) >= seconds", grace)

    def test_unlock_respects_biometric_preferences(self):
        screen = (ROOT / 'Vesper/Features/Settings/SettingsView.swift').read_text().split('struct AppLockScreen: View', 1)[1]
        self.assertNotIn('SourcePrivacyUnlockSheet', self.view)
        self.assertIn('@AppStorage(AppLock.biometricEnabledKey)', screen)
        self.assertIn('@AppStorage(AppLock.biometricPriorityKey)', screen)
        self.assertIn('await appLock.authenticateBiometrically(reason: biometricReason)', screen)
        self.assertIn('failures >= 2', screen)
        self.assertIn('biometricType != .none', screen)



if __name__ == '__main__':
    unittest.main()
