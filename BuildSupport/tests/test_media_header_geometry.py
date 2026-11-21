"""Exercise media header scroll boundaries and backdrop calculations."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MediaHeaderGeometryTests(unittest.TestCase):
    def test_scroll_range_glass_visibility_and_edge_strength(self):
        compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
        if not compiler:
            self.skipTest('Swift compiler unavailable')
        source = (ROOT / 'Vesper/Infrastructure/Navigation/VesperImmersiveTitle.swift').read_text()
        media_settings = (ROOT / 'Vesper/Features/Media/MediaView.swift').read_text()
        self.assertIn('mediaEdgeTopStrength', media_settings)
        self.assertIn('mediaEdgeBottomStrength', media_settings)
        self.assertIn('Color(uiColor: .systemBackground)', source)
        self.assertIn('curve: layout[.mediaEdgeCurve]', source)
        geometry = source.split('struct MediaHeaderGeometry {', 1)[1].split('/// Each root page', 1)[0]
        main = r'''
let open = MediaHeaderGeometry(pageOffset: 0, travel: 60)
precondition(open.progress == 0 && open.snapTarget == 0)
precondition(!open.showsGlass(at: 0, pageTop: 80, statusBarBottom: 60))
precondition(!open.showsGlass(at: 0, pageTop: 60, statusBarBottom: 60))
precondition(open.showsGlass(at: 0, pageTop: 0, statusBarBottom: 60))
let middle = MediaHeaderGeometry(pageOffset: 30, travel: 60)
precondition(middle.progress == 0.5 && middle.snapTarget == 1)
let nextPositionAfterOpenSnap = open.position(afterScrollDelta: 1, from: 0)
precondition(abs(nextPositionAfterOpenSnap - (1.0 / 60.0)) < 0.00001)
let nextPositionAfterMidScroll = middle.position(afterScrollDelta: 1, from: 0)
precondition(abs(nextPositionAfterMidScroll - (1.0 / 60.0)) < 0.00001)
precondition(middle.snapTarget(for: nextPositionAfterMidScroll) == 0)
precondition(middle.position(afterScrollDelta: 1, from: 1) == 1)
precondition(middle.position(afterScrollDelta: -60, from: 1) == 0)
precondition(middle.showsGlass(at: middle.progress, pageTop: 80, statusBarBottom: 60))
precondition(middle.showsGlass(at: 0.999, pageTop: 80, statusBarBottom: 60))
let collapsed = MediaHeaderGeometry(pageOffset: 60, travel: 60)
precondition(collapsed.progress == 1)
precondition(!collapsed.showsGlass(at: 1, pageTop: -20, statusBarBottom: 60))
precondition(collapsed.progress == MediaHeaderGeometry(pageOffset: 600, travel: 60).progress)
precondition(open.edgeRegionHeight(statusBarHeight: 60, position: 0) == 120)
precondition(collapsed.edgeRegionHeight(statusBarHeight: 60, position: 1) == 60)
precondition(open.edgeBlurProgress(position: 0, curve: 1) == 0)
let middleEase = middle.edgeBlurProgress(position: 0.5, curve: 1)
let endEase = collapsed.edgeBlurProgress(position: 1, curve: 1)
precondition(middleEase > 0 && endEase == 1)
let middleLinear = middle.edgeBlurProgress(position: 0.5, curve: 0)
let middleEaseIn = middle.edgeBlurProgress(position: 0.5, curve: 2)
let middleEaseOut = middle.edgeBlurProgress(position: 0.5, curve: 3)
let middleSmooth = middle.edgeBlurProgress(position: 0.5, curve: 4)
precondition(middleLinear != middleEaseIn && middleEaseIn != middleEaseOut)
precondition(middleSmooth == middleEase)
precondition(MediaHeaderGeometry(pageOffset: -30, travel: 60).progress == 0)
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            entry = folder / 'main.swift'
            entry.write_text('import Foundation\nstruct MediaHeaderGeometry {' + geometry + main)
            subprocess.run([compiler, '-swift-version', '6', str(entry), '-o', str(folder / 'checks')],
                           check=True, capture_output=True, text=True)
            subprocess.run([str(folder / 'checks')], check=True, capture_output=True, text=True)
