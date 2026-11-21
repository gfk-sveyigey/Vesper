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
        self.assertIn('isShowingEmbyEditor || editingEmby != nil, initial: true', sources)
        self.assertIn('headerVisibilityChanged(!presentsEditor)', sources)
        self.assertIn('SourcesView { sourcesHeaderVisible = $0 }', navigation)
        self.assertIn('sourcesPath.isEmpty && sourcesHeaderVisible', navigation)
