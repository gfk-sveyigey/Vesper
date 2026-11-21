"""Structural guards, not a substitute for on-device animation testing."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
class PlayerPresentationTests(unittest.TestCase):
    def test_detail_anchor_and_menu_groups(self):
        source = (ROOT / 'Vesper/Features/Media/EmbySeriesDetailView.swift').read_text()
        toolbar = source.split('GlassEffectContainer(spacing: 12)', 1)[1].split('.sharedBackgroundVisibility(.hidden)', 1)[0]
        self.assertEqual(toolbar.count('.glassEffectID("detailActionAnchor"'), 1)
        for distance in [56, 100, 144]:
            self.assertIn(f'DetailActionFan(collapsed: hasScrolled, distance: {distance})', toolbar)
        self.assertIn('@State private var hasScrolled = false', source)
        self.assertIn('Image(systemName: showsMultifunctionSymbol ? "ellipsis"', toolbar)
        self.assertIn('.animation(reduceMotion ? nil : .snappy(duration: 0.3),', toolbar)
        self.assertIn('.task(id: hasScrolled)', toolbar)
        self.assertIn('Section { favoriteButton }', toolbar)
        self.assertIn('versionMenu(inMenu: true)', toolbar)
        # Toolbar icons must not turn into menu text while collapsing.
        self.assertIn('versionMenu().frame(width: 44', toolbar)
        self.assertNotIn('if hasScrolled { Label', source)
        self.assertIn('.glassEffect(.regular, in: .circle)', toolbar)
    def test_rotation_sync_lifecycle(self):
        source = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        controller = source.split('final class PlayerVideoSurfaceController', 1)[1]
        self.assertIn('CADisplayLink(target: RotationGeometryTick', controller)
        self.assertIn('link.add(to: .main, forMode: .common)', controller)
        self.assertIn('weak var owner: PlayerVideoSurfaceController?', controller)
        self.assertIn('override func viewDidDisappear', controller)
        self.assertIn('return isVideo || !descendants.isEmpty ? [layer] + descendants : []', controller)
        self.assertLess(controller.index('let visible = layer.presentation()'), controller.index('// Capture presentation geometry'))
        self.assertIn('guard let self, self.rotationRevision == revision', controller)
