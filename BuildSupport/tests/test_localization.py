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
    def test_more_player_controls_setting_translation(self):
        expected = {
            'de.lproj': 'Steuerelemente immer anzeigen',
            'en.lproj': 'Always Show More Controls',
            'es.lproj': 'Mostrar siempre más controles',
            'fr.lproj': 'Toujours afficher plus de commandes',
            'ja.lproj': 'その他のコントロールを常に表示',
            'ko.lproj': '추가 제어 버튼 항상 표시',
            'zh-Hans.lproj': '常显更多控制按钮',
            'zh-Hant.lproj': '一律顯示更多控制項',
        }
        for locale, value in expected.items():
            path = ROOT / 'Vesper/Resources' / locale / 'Localizable.strings'
            pairs = {json.loads(k): json.loads(v) for k, v in ENTRY.findall(path.read_text())}
            self.assertEqual(pairs['常显更多控制按钮'], value, locale)
    def test_app_permissions_setting_opens_system_settings_directly(self):
        settings = (ROOT / 'Vesper/Features/Settings/SettingsView.swift').read_text()
        self.assertIn('appPermissionsButton\n                    Divider()', settings)
        button = settings.split('private var appPermissionsButton: some View {', 1)[1].split('@ViewBuilder', 1)[0]
        self.assertIn('settingsLinkLabel("应用权限", symbol: "hand.raised")', button)
        self.assertIn('URL(string: UIApplication.openSettingsURLString)', button)
        self.assertIn('UIApplication.shared.open(url)', button)
        routes = settings.split('private enum SettingsRoute: Hashable {', 1)[1].split('var title:', 1)[0]
        self.assertNotRegex(routes, r'\bpermissions\b')
        self.assertFalse((ROOT / 'Vesper/Features/Settings/AppPermissionsView.swift').exists())
        project = (ROOT / 'Vesper.xcodeproj/project.pbxproj').read_text()
        self.assertNotIn('AppPermissionsView.swift', project)

    def test_settings_cards(self):
        pages = {
            'Settings/AppearanceSettingsView.swift': ['AppearanceSettingsView'],
            'Settings/EmbySettingsView.swift': ['EmbySettingsView'],
            'Settings/PlaybackLicensesView.swift': ['PlaybackLicensesView'],
            'Settings/RuntimeLogsView.swift': ['RuntimeLogsView'],
            'Settings/TabSettingsView.swift': ['TabSettingsView'],
            'Settings/SettingsView.swift': [],
            'Settings/DebugSettingsView.swift': ['DebugSettingsView'],
            'Settings/CacheManagementView.swift': [],
            'Settings/PlaybackSettingsView.swift': ['PlaybackSettingsView', 'SubtitleSettingsView', 'DanmakuSettingsView'],
            'Settings/PlayerGestureSettingsView.swift': ['PlayerGestureSettingsView'],
            'Sources/EmbyIconLibraryViews.swift': ['EmbyIconLibrarySettingsView'],
            'Player/DanmakuAPISettingsView.swift': ['DanmakuAPISettingsView'],
        }
        for file, views in pages.items():
            source = (ROOT / 'Vesper/Features' / file).read_text()
            for view in views:
                block = re.split(r'\n(?:private )?struct ', source.split('struct '+view+':', 1)[1], maxsplit=1)[0]
                if view != 'CacheManagementView':
                    self.assertIn('SettingsIntroCard(', block, view)
        source = (ROOT / 'Vesper/Features/Settings/SettingsComponents.swift').read_text()
        self.assertIn('class IntroCardTableView', (ROOT / 'Vesper/Features/Settings/CacheManagementView.swift').read_text())
        card = source.split('struct SettingsIntroCard: View {', 1)[1].split('/// Match the standard', 1)[0]
        self.assertNotIn('\\.isPresented', card)
        self.assertIn('@Environment(\\.settingsIntroCardsHidden)', card)
        self.assertIn('if !introCardsHidden {', card)
        # Navigation pages must opt out only at actual sheet entry points.
        key = source.split('private struct SettingsIntroCardsHiddenKey:', 1)[1].split('extension EnvironmentValues', 1)[0]
        self.assertIn('static let defaultValue = false', key)
        player = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        panel = player.split('.sheet(item: $panel,', 1)[1].split('.alert(', 1)[0]
        self.assertIn('.environment(\\.settingsIntroCardsHidden, true)', panel)
        icons = (ROOT / 'Vesper/Features/Sources/EmbyIconLibraryViews.swift').read_text()
        library_sheet = icons.split('.sheet(isPresented: $showingLibrarySettings)', 1)[1].split('.onAppear', 1)[0]
        self.assertIn('.environment(\\.settingsIntroCardsHidden, true)', library_sheet)

    def test_sheet_settings_have_no_intro_cards(self):
        sheets = {
            'Settings/SettingsView.swift': ['TabOrderSettingsView', 'EmbyProgressPrioritySheet'],
            'Settings/EmbySkipDatabasesView.swift': ['EmbySkipDatabasesView', 'EmbySkipDatabaseEditor'],
            'Settings/PlayerGestureSettingsView.swift': ['GesturePairSettingsView', 'GestureRegionSettingsView'],
            'Sources/EmbyIconLibraryViews.swift': ['EmbyIconLibraryEditor'],
            'Player/DanmakuAPISettingsView.swift': ['DanmakuAPIEditor'],
        }
        for file, views in sheets.items():
            source = (ROOT / 'Vesper/Features' / file).read_text()
            for view in views:
                block = re.split(r'\n(?:private )?struct ', source.split('struct '+view+':', 1)[1], maxsplit=1)[0]
                self.assertNotIn('SettingsIntroCard(', block, view)
    def test_danmaku_submenu(self):
        source = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        self.assertIn('[speedMenu(), audioMenu(), subtitleMenu(), danmakuMenu(), introOutroMenu()]', source)
