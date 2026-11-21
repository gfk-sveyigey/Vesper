"""Keep all shipped languages complete and safe for formatted runtime strings."""
import json
from pathlib import Path
import re
import unittest
ROOT = Path(__file__).resolve().parents[2]
ENTRY = re.compile(r'^\s*("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");\s*$', re.M)
PLACEHOLDER = re.compile(r'%(?!%)(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dfius]')
class LocalizationTests(unittest.TestCase):
    def test_catalogs(self):
        catalogs = {}
        for path in sorted((ROOT / 'Vesper/Resources').glob('*.lproj/Localizable.strings')):
            pairs = [(json.loads(k), json.loads(v)) for k, v in ENTRY.findall(path.read_text())]
            self.assertTrue(pairs, str(path))
            self.assertEqual(len(pairs), len(dict(pairs)), f'Duplicate keys: {path}')
            catalogs[path.parent.name] = dict(pairs)
        self.assertEqual(len(catalogs), 8)
        reference = catalogs['zh-Hans.lproj']
        for locale, entries in catalogs.items():
            self.assertEqual(set(entries), set(reference), locale)
            for key, value in entries.items():
                self.assertTrue(value.strip(), (locale, key))
                self.assertEqual(sorted(PLACEHOLDER.findall(key)), sorted(PLACEHOLDER.findall(value)), (locale, key))
    def test_settings_cards(self):
        source = (ROOT / 'Vesper/Features/Settings/SettingsView.swift').read_text()
        for view in ['EmbySettingsView', 'AppPermissionsView', 'TabOrderSettingsView', 'EmbySkipDatabasesView', 'EmbySkipDatabaseEditor']:
            block = source.split('struct '+view+':', 1)[1].split('\nprivate struct ', 1)[0]
            self.assertIn('SettingsIntroCard(', block, view)
        self.assertIn('class IntroCardTableView', source)
    def test_danmaku_submenu(self):
        source = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        self.assertIn('[speedMenu(), audioMenu(), subtitleMenu(), danmakuMenu()]', source)
