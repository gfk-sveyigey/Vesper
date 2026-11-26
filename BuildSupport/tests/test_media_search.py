"""Exercise the production search repository and recursive local source search."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc')

class MediaSearchTests(unittest.TestCase):
    def test_thumbnail_context_preview_does_not_require_source_environment_object(self):
        source = (ROOT / 'Vesper/Features/Media/MediaThumbnail.swift').read_text()
        self.assertNotIn('@EnvironmentObject private var library: SourceLibrary', source)
        self.assertIn('service: MediaSourceServices.artwork', source)

    def test_recent_search_history_uses_native_list_swipe_actions(self):
        navigation = (ROOT / 'Vesper/Features/Navigation/AppNavigationView.swift').read_text()
        root_list = (ROOT / 'Vesper/Infrastructure/Navigation/VesperImmersiveTitle.swift').read_text()
        self.assertIn('let showsRecentSearches = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty', navigation)
        self.assertIn('usesSystemList: showsRecentSearches', navigation)
        self.assertIn('.swipeActions(edge: .trailing, allowsFullSwipe: true)', navigation)
        self.assertIn('if usesSystemList {\n                List {', root_list)
        self.assertNotIn('RecentSearchHistoryRow', navigation)

    def test_clear_search_history_belongs_to_recent_search_header(self):
        navigation = (ROOT / 'Vesper/Features/Navigation/AppNavigationView.swift').read_text()
        search = navigation.split('Tab("搜索"', 1)[1].split('.modifier(VesperNavigationHeaderLayer', 1)[0]
        actions = search.split('} actions: {', 1)[1].split('.searchable(', 1)[0]
        self.assertIn('if showsRecentSearches, !recentSearches.isEmpty {', actions)
        self.assertIn('.accessibilityLabel("清空搜索历史")', actions)
        self.assertNotIn('.toolbar {', search)

    def test_search_loading_uses_centered_empty_content_style(self):
        navigation = (ROOT / 'Vesper/Features/Navigation/AppNavigationView.swift').read_text()
        search = navigation.split('struct MediaSearchResultsView:', 1)[1].split('private func resultList', 1)[0]
        self.assertIn('ProgressView()\n                        .controlSize(.large)', search)
        self.assertIn('Text("正在搜索")\n                        .font(.title3.weight(.semibold))', search)
        self.assertIn('.offset(y: -rootHeaderHeight / 2)', search)
        self.assertNotIn('symbol: "magnifyingglass"', search)

    @unittest.skipUnless(SWIFTC, 'Swift compiler is required')
    def test_emby_search_pagination_and_query_encoding(self):
        subprocess.run([sys.executable, str(ROOT / 'BuildSupport/tests/run_emby_checks.py')],
                       cwd=ROOT, check=True)

    @unittest.skipUnless(SWIFTC and sys.platform == 'darwin', 'macOS Swift compiler is required for security-scoped files')
    def test_recursive_local_search_and_source_containment(self):
        with tempfile.TemporaryDirectory(prefix='vesper-local-search-') as folder:
            binary = str(Path(folder) / 'checks')
            subprocess.run([SWIFTC, '-swift-version', '6', '-strict-concurrency=complete',
                            str(ROOT / 'Vesper/Infrastructure/Theme/VesperLocalization.swift'),
                            str(ROOT / 'Vesper/Infrastructure/Sources/LocalFileStore.swift'),
                            str(ROOT / 'Tests/LocalFileStoreChecks.swift'), '-o', binary], check=True)
            subprocess.run([binary], check=True)
