from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SourcePrivacyModeTests(unittest.TestCase):
    def setUp(self):
        self.view = (ROOT / 'Vesper/Features/Sources/SourcesView.swift').read_text()
        self.library = (ROOT / 'Vesper/Infrastructure/Sources/SourceLibrary.swift').read_text()

    def test_existing_password_and_distinct_icons(self):
        self.assertIn('appLock.verify(digits)', self.view)
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
        self.assertIn('sources.filter { isPrivacyModeEnabled || !protectedSourceIDs.contains($0.id) }', self.library)
        self.assertIn('for source in visibleSources where source.kind == .emby', self.library)
        self.assertIn('guard isPrivacyModeEnabled || !protectedSourceIDs.contains(id)', self.library)
        self.assertIn('library.testProtectedRouteLatencies()', self.view)
        self.assertIn('ForEach(library.visibleSources)', self.view)
        media = (ROOT / 'Vesper/Features/Media/MediaView.swift').read_text()
        self.assertIn('ForEach(library.visibleSources)', media)

    def test_unlock_respects_biometric_preferences(self):
        sheet = self.view.split('private struct SourcePrivacyUnlockSheet', 1)[1].split('private struct SourceOrderSheet', 1)[0]
        self.assertIn('@AppStorage(AppLock.biometricEnabledKey)', sheet)
        self.assertIn('@AppStorage(AppLock.biometricPriorityKey)', sheet)
        self.assertIn('if biometricEnabled, biometricPriority', sheet)
        self.assertIn('await appLock.authenticateBiometrically()', sheet)
        self.assertIn('!Task.isCancelled, isVisible, appLock.isEnabled', sheet)
        self.assertIn('pinFocused = true', sheet)


if __name__ == '__main__':
    unittest.main()
