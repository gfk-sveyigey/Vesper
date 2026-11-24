"""Portable checks for the production icon-library parser."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class EmbyIconLibraryTests(unittest.TestCase):
    def test_parser_and_saved_links(self):
        compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
        if not compiler:
            self.skipTest('Swift compiler unavailable')
        main = r'''
import Foundation

let json = #"""
{
  "name": "Example Emby icons",
  "description": "Library description",
  "icons": [
    {"name": "emby", "url": "https:\/\/raw.githubusercontent.com\/example\/icons\/emby.png"},
    {"name": "duplicate", "url": "https://raw.githubusercontent.com/example/icons/emby.png"},
    {"name": "other", "url": "https://example.com/icon(1).png"},
    {"name": "insecure", "url": "http://example.com/a.png"},
    {"name": "credentials", "url": "https://user:pass@example.com/a.png"},
    {"name": "", "url": "https://example.com/empty.png"}
  ]
}
"""#
let catalog = try EmbyIconCatalog.parse(Data(json.utf8))
precondition(catalog.name == "Example Emby icons")
precondition(catalog.description == "Library description")
precondition(catalog.icons.count == 2)
precondition(catalog.icons[0].name == "emby")
precondition(catalog.icons[0].url.absoluteString == "https://raw.githubusercontent.com/example/icons/emby.png")
precondition(catalog.icons[1].url.absoluteString.hasSuffix("icon(1).png"))
for input in ["invalid", "{}", #"{"name":"Empty","icons":[]}"#,
              #"{"name":" ","icons":[{"name":"test","url":"https://example.com/test.png"}]}"#] {
    do { _ = try EmbyIconCatalog.parse(Data(input.utf8)); fatalError("Accepted invalid catalog") }
    catch EmbyIconLibraryError.invalidCatalog {} catch { fatalError("Wrong error") }
}
do {
    _ = try EmbyIconCatalog.parse(Data(repeating: 32, count: 3 * 1024 * 1024 + 1))
    fatalError("Accepted oversized catalog")
} catch EmbyIconLibraryError.invalidCatalog {}
for url in ["http://example.com/icons.json", "file:///tmp/icons.json", "https://u:p@example.com/a", "not-a-url"] {
    do { _ = try EmbyIconLibraryClient.url(url); fatalError("Accepted unsafe URL") }
    catch EmbyIconLibraryError.invalidAddress {}
}
let checkedURL = try EmbyIconLibraryClient.url("  https://example.com/lib.json?token=abc \n")
precondition(checkedURL.query == "token=abc")
let link = EmbyIconLibraryLink(name: catalog.name, address: "https://example.com/icons.json")
let data = try JSONEncoder().encode([link])
let decoded = try JSONDecoder().decode([EmbyIconLibraryLink].self, from: data)
precondition(decoded == [link])
if CommandLine.arguments.count > 1 {
    let actual = try EmbyIconCatalog.parse(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    print("Verified supplied library: \(actual.name), \(actual.icons.count) icons")
}
print("Icon library parser checks passed.")
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'main.swift').write_text(main)
            subprocess.run([compiler, '-swift-version', '6',
                            str(ROOT / 'Vesper/Infrastructure/Theme/VesperLocalization.swift'),
                            str(ROOT / 'Vesper/Infrastructure/Sources/EmbyIconLibrary.swift'),
                            str(folder / 'main.swift'), '-o', str(folder / 'checks')],
                           check=True, capture_output=True, text=True)
            args = [str(folder / 'checks')]
            if os.environ.get('EMBY_ICON_LIBRARY_FIXTURE'):
                args.append(os.environ['EMBY_ICON_LIBRARY_FIXTURE'])
            result = subprocess.run(args, check=True, capture_output=True, text=True)
            print(result.stdout.strip())

    def test_ui_entrypoints_and_registration(self):
        settings = (ROOT / 'Vesper/Features/Settings/EmbySettingsView.swift').read_text()
        editor = (ROOT / 'Vesper/Features/Sources/EmbySourceEditor.swift').read_text()
        self.assertIn('NavigationLink("图标库") { EmbyIconLibrarySettingsView() }', settings)
        self.assertIn('Button("从图标库选择"', editor)
        self.assertIn('EmbyLibraryIconPicker { data in', editor)
        project = (ROOT / 'Vesper.xcodeproj/project.pbxproj').read_text()
        for name in ['EmbyIconLibrary.swift', 'EmbyIconLibraryViews.swift']:
            self.assertIn(name, project)
