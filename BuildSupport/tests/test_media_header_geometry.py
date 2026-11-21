"""Exercise the production header geometry independently of SwiftUI/UIKit."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MediaHeaderGeometryTests(unittest.TestCase):
    def test_screen_anchors_and_mutually_exclusive_backdrops(self):
        compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
        if not compiler:
            self.skipTest('Swift compiler unavailable')
        source = (ROOT / 'Vesper/Infrastructure/Navigation/VesperImmersiveTitle.swift').read_text()
        geometry = source.split('struct MediaHeaderGeometry {', 1)[1].split('/// Each root page', 1)[0]
        main = r'''
func check(_ offset: CGFloat, _ progress: CGFloat, _ glass: Bool, _ edge: Bool) {
    let geometry = MediaHeaderGeometry(pageOffset: offset, safeAreaHeight: 60)
    precondition(abs(geometry.progress - progress) < 0.00001)
    precondition(geometry.showsGlass(at: progress) == glass)
    precondition(geometry.showsEdge(at: progress) == edge)
}
check(-40, 0, false, false) // Pull down: pin header to the screen, no backdrop.
check(0, 0, false, false)
check(15, 0.25, true, false)
check(30, 0.5, true, false)
check(60, 1, false, true) // Title top reaches screen top.
check(500, 1, false, true)
for offset: CGFloat in [-40, 0, 15, 30, 60, 500] {
    let geometry = MediaHeaderGeometry(pageOffset: offset, safeAreaHeight: 60)
    for position: CGFloat in [0, 0.25, 0.75, 1] {
        precondition(!(geometry.showsGlass(at: position) && geometry.showsEdge(at: position)))
    }
}
precondition(MediaHeaderGeometry(pageOffset: 29, safeAreaHeight: 60).snapTarget == 0)
precondition(MediaHeaderGeometry(pageOffset: 30, safeAreaHeight: 60).snapTarget == 1)
precondition(MediaHeaderGeometry(pageOffset: 0, safeAreaHeight: 0).progress.isFinite)
precondition(MediaHeaderGeometry(pageOffset: 0, safeAreaHeight: 60).showsGlass(at: 0.5))
precondition(MediaHeaderGeometry(pageOffset: 10, safeAreaHeight: 60).showsGlass(at: 0))
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            entry = folder / 'main.swift'
            entry.write_text('import Foundation\nstruct MediaHeaderGeometry {' + geometry + main)
            subprocess.run([compiler, '-swift-version', '6', str(entry), '-o', str(folder / 'checks')],
                           check=True, capture_output=True, text=True)
            subprocess.run([str(folder / 'checks')], check=True, capture_output=True, text=True)
