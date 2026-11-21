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
        self.assertIn('mediaEdgeTint', media_settings)
        self.assertIn('Color(uiColor: .systemBackground)', source)
        self.assertIn('tintStrength: Double(layout[.mediaEdgeTint]) / 100', source)
        self.assertIn('opacity(tintStrength * $0)', source)
        self.assertIn('curve: layout[.mediaEdgeCurve]', source)
        self.assertIn('curveProgress(position: position, curve: layout[.mediaContentBlurCurve])', source)
        self.assertIn('headerOpacity(position: position, curve: layout[.mediaContentOpacityCurve])', source)
        self.assertIn('Double(layout[.mediaSnapDuration]) / 1000', source)
        self.assertIn('curve: layout[.mediaSnapCurve]', source)
        self.assertIn('let threshold = CGFloat(layout[.mediaSnapThreshold]) / 100', source)
        geometry = source.split('struct MediaHeaderGeometry {', 1)[1].split('/// Each root page', 1)[0]
        main = r'''
let open = MediaHeaderGeometry(pageOffset: 0, travel: 60)
precondition(open.progress == 0 && open.snapTarget == 0)
precondition(!open.showsGlass(at: 0, pageTop: 80, statusBarBottom: 60))
precondition(!open.showsGlass(at: 0, pageTop: 60, statusBarBottom: 60))
precondition(open.showsGlass(at: 0, pageTop: 0, statusBarBottom: 60))
let middle = MediaHeaderGeometry(pageOffset: 30, travel: 60)
precondition(middle.progress == 0.5 && middle.snapTarget == 1)
precondition(open.snapTarget(for: 0.4, threshold: 0.3, startingTarget: 0) == 1)
precondition(open.snapTarget(for: 0.8, threshold: 0.3, startingTarget: 1) == 1)
precondition(open.snapTarget(for: 0.7, threshold: 0.3, startingTarget: 1) == 0)
precondition(open.headerOpacity(position: 0, curve: 2) == 1)
let nextPositionAfterOpenSnap = open.position(afterScrollDelta: 1, from: 0)
precondition(abs(nextPositionAfterOpenSnap - (1.0 / 60.0)) < 0.00001)
let nextPositionAfterMidScroll = middle.position(afterScrollDelta: 1, from: 0)
precondition(abs(nextPositionAfterMidScroll - (1.0 / 60.0)) < 0.00001)
precondition(middle.snapTarget(for: nextPositionAfterMidScroll) == 0)
precondition(middle.position(afterScrollDelta: 1, from: 1) == 1)
precondition(middle.position(afterScrollDelta: -60, from: 1) == 0)
let topOffset = open.boundedScrollOffset(0, maximum: 500)
let pulledPastTop = open.boundedScrollOffset(-24, maximum: 500)
precondition(topOffset == pulledPastTop)
precondition(open.position(afterScrollDelta: pulledPastTop - topOffset, from: 0) == 0)
precondition(open.boundedScrollOffset(900, maximum: 500) == 500)
precondition(middle.showsGlass(at: middle.progress, pageTop: 80, statusBarBottom: 60))
precondition(middle.showsGlass(at: 0.999, pageTop: 80, statusBarBottom: 60))
let collapsed = MediaHeaderGeometry(pageOffset: 60, travel: 60)
precondition(collapsed.progress == 1)
precondition(!collapsed.showsGlass(at: 1, pageTop: -20, statusBarBottom: 60))
precondition(collapsed.progress == MediaHeaderGeometry(pageOffset: 600, travel: 60).progress)
precondition(open.edgeRegionHeight(statusBarHeight: 60, position: 0) == 120)
precondition(collapsed.edgeRegionHeight(statusBarHeight: 60, position: 1) == 60)
precondition(open.curveProgress(position: 0, curve: 1) == 0)
let middleEase = middle.curveProgress(position: 0.5, curve: 1)
let endEase = collapsed.curveProgress(position: 1, curve: 1)
precondition(middleEase > 0 && endEase == 1)
let middleLinear = middle.curveProgress(position: 0.5, curve: 0)
let middleEaseIn = middle.curveProgress(position: 0.5, curve: 2)
let middleEaseOut = middle.curveProgress(position: 0.5, curve: 3)
let middleSmooth = middle.curveProgress(position: 0.5, curve: 4)
precondition(middleLinear != middleEaseIn && middleEaseIn != middleEaseOut)
precondition(middleSmooth == middleEase)
let profiles = (0...4).map { open.edgeBlurSamples(top: 0.8, bottom: 0.2, curve: $0) }
for profile in profiles {
    precondition(abs(profile.first! - 0.8) < 0.00001 && abs(profile.last! - 0.2) < 0.00001)
}
precondition(Set(profiles.map { $0[8] }).count == 5)
let reversed = open.edgeBlurSamples(top: 0, bottom: 1, curve: 1)
precondition(reversed.first == 0 && reversed.last == 1)
precondition(MediaHeaderGeometry(pageOffset: -30, travel: 60).progress == 0)
let opacityProfiles = (0...4).map { open.headerOpacity(position: 0.25, curve: $0) }
precondition(Set(opacityProfiles).count == 5)
precondition(collapsed.headerOpacity(position: 1, curve: 3) == 0)
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            entry = folder / 'main.swift'
            entry.write_text('import Foundation\nstruct MediaHeaderGeometry {' + geometry + main)
            subprocess.run([compiler, '-swift-version', '6', str(entry), '-o', str(folder / 'checks')],
                           check=True, capture_output=True, text=True)
            subprocess.run([str(folder / 'checks')], check=True, capture_output=True, text=True)
