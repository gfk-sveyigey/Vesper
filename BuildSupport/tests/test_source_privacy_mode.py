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

    def test_exit_stops_playback_independently_of_selected_source(self):
        toggle = self.view.split('private func togglePrivacyMode()', 1)[1].split('private var iconInset', 1)[0]
        self.assertIn('protectedSourceIDs.contains(item.id.sourceID)', toggle)
        self.assertLess(toggle.index('playback.stop()'), toggle.index('library.setPrivacyMode(false)'))
        exit_mode = self.library.split('func setPrivacyMode', 1)[1].split('func testProtected', 1)[0]
        self.assertIn('self.selectedID = visibleSources.first?.id', exit_mode)
        self.assertIn('embyParentStack.removeAll()', exit_mode)
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
