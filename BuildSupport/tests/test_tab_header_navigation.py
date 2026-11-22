"""Guard root header visibility against untracked detail presentation."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2] / 'Vesper/Features'

class TabHeaderNavigationTests(unittest.TestCase):
    def test_history_uses_stack_path(self):
        history = (ROOT / 'History/HistoryView.swift').read_text()
        navigation = (ROOT / 'Navigation/AppNavigationView.swift').read_text()
        self.assertIn('@Binding var path: NavigationPath', history)
        self.assertIn('path.append(HistoryDetailRoute(source: source, item: item))', history)
        self.assertIn('.navigationDestination(for: HistoryDetailRoute.self)', history)
        self.assertNotIn('.navigationDestination(item:', history)
        self.assertIn('HistoryView(path: $historyPath)', navigation)
        self.assertIn('VesperNavigationHeaderLayer(isRoot: historyPath.isEmpty)', navigation)

    def test_source_editor_hides_root_header(self):
        sources = (ROOT / 'Sources/SourcesView.swift').read_text()
        navigation = (ROOT / 'Navigation/AppNavigationView.swift').read_text()
        self.assertIn('isShowingEmbyEditor || editingEmby != nil || sourceManagement != nil || showingOrder, initial: true', sources)
        self.assertIn('headerVisibilityChanged(!presentsEditor)', sources)
        self.assertIn('SourcesView { sourcesHeaderVisible = $0 }', navigation)
        self.assertIn('sourcesPath.isEmpty && sourcesHeaderVisible', navigation)

    def test_password_protection_uses_settings_stack_path(self):
        navigation = (ROOT / 'Navigation/AppNavigationView.swift').read_text()
        settings = (ROOT / 'Settings/SettingsView.swift').read_text()
        self.assertIn('SettingsView(path: $settingsPath)', navigation)
        self.assertIn('VesperNavigationHeaderLayer(isRoot: settingsPath.isEmpty)', navigation)
        self.assertIn('appLock.requestAuthentication(.settingsAccess) { path.append(route) }', settings)
        self.assertNotIn('.navigationDestination(isPresented:', settings)

    def test_all_tab_roots_share_media_header_and_disable_native_edges(self):
        header = (ROOT.parent / 'Infrastructure/Navigation/VesperImmersiveTitle.swift').read_text()
        root = header.split('struct VesperRootScrollView<', 1)[1].split('private struct VesperHeaderMotionEffect', 1)[0]
        self.assertIn('usesMediaScrollEdges: Bool = true', root)
        self.assertIn('.scrollEdgeEffectHidden(true, for: [.top, .bottom])', root)
        self.assertNotIn('.scrollEdgeEffectStyle(', root)
        for name, title in [('Settings/SettingsView.swift', '设置'),
                            ('History/HistoryView.swift', '记录'),
                            ('Sources/SourcesView.swift', '来源')]:
            page = (ROOT / name).read_text()
            self.assertIn('VesperRootScrollView(title: "' + title + '")', page)
            self.assertNotIn('usesMediaScrollEdges: false', page)

    def test_search_has_one_root_scroll_and_tracks_detail_path(self):
        navigation = (ROOT / 'Navigation/AppNavigationView.swift').read_text()
        search = navigation.split('Tab("搜索",', 1)[1].split('.onChange(of: hidden)', 1)[0]
        self.assertIn('NavigationStack(path: $searchPath)', search)
        self.assertIn('VesperRootScrollView(title:', search)
        self.assertIn('searchPath.append(SearchMediaRoute(', search)
        self.assertIn('.navigationDestination(for: SearchMediaRoute.self)', search)
        self.assertIn('VesperNavigationHeaderLayer(isRoot: searchPath.isEmpty)', search)
        self.assertNotIn('List {', search)
        results = navigation.split('private struct MediaSearchResultsView:', 1)[1]
        self.assertNotIn('List {', results)
        self.assertNotIn('ScrollView {', results)
        self.assertNotIn('.navigationDestination(item:', results)
