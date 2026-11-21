"""Run the production Foundation XML parser without an Apple SDK."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class DanmakuTests(unittest.TestCase):
    def test_parser(self):
        compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
        if not compiler:
            self.skipTest('Swift compiler unavailable')
        main = r'''
import Foundation
func parse(_ xml: String) throws -> [DanmakuComment] {
    try DanmakuXMLParser.parse(Data(xml.utf8))
}
let entries = try parse("""
<i><d p="2,1,25,16777215">hello &amp; world</d>
<d p="1,5,25,255">top</d><d p="1,4,25,1">bottom</d>
<d p="nan,1,25,0">bad</d><d p="-1,1,25,0">bad</d>
<d p="3,7,25,0">unsupported</d><d p="4,1,25,999999999">bad</d></i>
""")
assert(entries.count == 3)
assert(entries[0].text == "top" && entries[1].text == "bottom")
assert(entries[2].text == "hello & world" && entries[2].time == 2)
for xml in ["not xml", "<i></i>", "<i><d p='1,1,25,0'>broken"] {
    do { _ = try parse(xml); fatalError("Should reject invalid document") } catch {}
}
do {
    _ = try DanmakuXMLParser.parse(Data(repeating: 32, count: 16 * 1024 * 1024 + 1))
    fatalError("Should reject oversized data")
} catch DanmakuImportError.tooLarge {} catch { fatalError("Wrong error") }
let long = try parse("<i><d p='1,1,25,0'>" + String(repeating: "字", count: 1000) + "</d></i>")
assert(long[0].text.count == 500)
let many = "<i>" + String(repeating: "<d p='1,1,25,0'>a</d>", count: 50001) + "</i>"
do { _ = try parse(many); fatalError("Should reject too many comments") }
catch DanmakuImportError.tooLarge {} catch { fatalError("Wrong count error") }
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'main.swift').write_text(main)
            subprocess.run([compiler, str(ROOT / 'Vesper/Infrastructure/Theme/VesperLocalization.swift'), str(ROOT / 'Vesper/Features/Player/DanmakuDocument.swift'),
                            str(folder / 'main.swift'), '-o', str(folder / 'test')], check=True,
                           capture_output=True, text=True)
            subprocess.run([str(folder / 'test')], check=True, capture_output=True, text=True)


class DanmakuAPITests(unittest.TestCase):
    def test_api_urls_and_json(self):
        compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
        if not compiler:
            self.skipTest('Swift compiler unavailable')
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'main.swift').write_text((ROOT / 'Tests/Fixtures/DanmakuAPIChecks.swift').read_text())
            sources = ROOT / 'Vesper/Features/Player'
            subprocess.run([compiler, '-swift-version', '6', str(ROOT / 'Vesper/Infrastructure/Theme/VesperLocalization.swift'), str(sources / 'DanmakuDocument.swift'),
                            str(sources / 'DanmakuAPI.swift'), str(folder / 'main.swift'),
                            '-o', str(folder / 'test')], check=True, capture_output=True, text=True)
            subprocess.run([str(folder / 'test')], check=True, capture_output=True, text=True)
