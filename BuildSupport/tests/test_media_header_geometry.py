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
        self.assertIn('mediaEdgeTint', media_settings)
        self.assertIn('tintOpacity: Double(layout[.mediaEdgeTint]) / 100', source)
        geometry = source.split('struct MediaHeaderGeometry {', 1)[1].split('/// Each root page', 1)[0]
        main = r'''
let open = MediaHeaderGeometry(pageOffset: 0, travel: 60)
precondition(open.progress == 0 && open.snapTarget == 0)
precondition(!open.showsGlass(at: 0, pageTop: 80, statusBarBottom: 60))
precondition(open.showsGlass(at: 0, pageTop: 0, statusBarBottom: 60))
let middle = MediaHeaderGeometry(pageOffset: 30, travel: 60)
precondition(middle.progress == 0.5 && middle.snapTarget == 1)
precondition(middle.showsGlass(at: middle.progress, pageTop: 80, statusBarBottom: 60))
let collapsed = MediaHeaderGeometry(pageOffset: 60, travel: 60)
precondition(collapsed.progress == 1)
precondition(!collapsed.showsGlass(at: 1, pageTop: -20, statusBarBottom: 60))
precondition(collapsed.progress == MediaHeaderGeometry(pageOffset: 600, travel: 60).progress)
precondition(open.edgeRegionHeight(statusBarHeight: 60, position: 0) == 120)
precondition(collapsed.edgeRegionHeight(statusBarHeight: 60, position: 1) == 60)
precondition(open.edgeBlurProgress(statusBarHeight: 60, position: 0) == 1)
let half = middle.edgeBlurProgress(statusBarHeight: 60, position: 0.5)
let end = collapsed.edgeBlurProgress(statusBarHeight: 60, position: 1)
precondition(half > end && end > 0 && half < 1)
let quarter = MediaHeaderGeometry(pageOffset: 45, travel: 60).edgeBlurProgress(statusBarHeight: 60, position: 0.75)
precondition(quarter < half && quarter > end)
precondition(MediaHeaderGeometry(pageOffset: -30, travel: 60).progress == 0)
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            entry = folder / 'main.swift'
            entry.write_text('import Foundation\nstruct MediaHeaderGeometry {' + geometry + main)
            subprocess.run([compiler, '-swift-version', '6', str(entry), '-o', str(folder / 'checks')],
                           check=True, capture_output=True, text=True)
            subprocess.run([str(folder / 'checks')], check=True, capture_output=True, text=True)
