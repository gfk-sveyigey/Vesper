from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SourceContextManagementTests(unittest.TestCase):
    def test_icon_and_route_actions_use_independent_sheets(self):
        sources = (ROOT / "Vesper/Features/Sources/SourcesView.swift").read_text()
        self.assertIn('sourceManagement = .icon(source)', sources)
        self.assertIn('sourceManagement = .routes(source)', sources)
        self.assertIn("SourceIconEditSheet(source: source)", sources)
        self.assertIn("SourceRouteManagementSheet(source: source)", sources)
        self.assertNotIn("entry: .icon", sources)
        self.assertNotIn("entry: .routes", sources)

    def test_active_route_is_retained_and_retested_after_address_change(self):
        source = (ROOT / "Vesper/Infrastructure/Sources/SourceLibrary.swift").read_text()
        update = source.split("func updateEmbyRoutes", 1)[1].split("func switchEmbyRoute", 1)[0]
        self.assertIn("guard let activeRoute", update)
        self.assertIn("configuration.serverAddress = activeRoute.address", update)
        self.assertIn("verifyEmbyConnection(id)", update)

    def test_route_switch_menus_share_icon_and_reserve_unselected_checkmark_space(self):
        sources = (ROOT / "Vesper/Features/Sources/SourcesView.swift").read_text()
        media = (ROOT / "Vesper/Features/Media/MediaView.swift").read_text()
        self.assertIn('Menu("切换线路", systemImage: "arrow.left.arrow.right")', sources)
        self.assertIn('Text("切换线路") } icon: { menuSymbol("arrow.left.arrow.right")', media)
        self.assertIn('menuSymbol("checkmark", visible: isSelected)\n                    .frame(width: 20, height: 20)', media)
        source_menu = sources.split('Menu("切换线路"', 1)[1].split("Button(\"移除来源\"", 1)[0]
        self.assertIn('Image(systemName: "checkmark")\n                                                        .frame(width: 20, height: 20)', source_menu)
        self.assertIn('.accessibilityHidden(key != EmbyRouteOptions.key(configuration.serverAddress))', source_menu)

    def test_emby_home_failure_does_not_restore_disk_cache(self):
        source = (ROOT / "Vesper/Infrastructure/Sources/SourceLibrary.swift").read_text()
        loader = source.split("private func loadEmbyMediaGroups", 1)[1].split("private func prepareCarousel", 1)[0]
        failure = loader.rsplit("} catch {", 1)[1]
        self.assertIn("embyHome = nil", failure)
        self.assertIn("content = .failed", failure)
        self.assertNotIn("cache.items", failure)
        self.assertIn('cache.save(libraries, scope: scope, key: "libraries:media-only"', loader)
        self.assertIn('key: "latest:titles:', loader)
        self.assertIn('key: "featured:titles"', loader)

    def test_emby_cache_is_preview_only_and_refresh_failure_is_reported(self):
        source = (ROOT / "Vesper/Infrastructure/Sources/SourceLibrary.swift").read_text()
        loader = source.split("private func loadEmbyMediaGroups", 1)[1].split("private func prepareCarousel", 1)[0]
        media = (ROOT / "Vesper/Features/Media/MediaView.swift").read_text()
        self.assertIn('cache.items(scope: scope, key: "libraries:media-only")', loader)
        self.assertIn('key: "latest:titles:', loader)
        self.assertIn('if group.isLoading && group.items.isEmpty', media)
        self.assertIn('if groupLoadFailed { throw EmbyError.invalidResponse }', loader)


if __name__ == "__main__":
    unittest.main()
