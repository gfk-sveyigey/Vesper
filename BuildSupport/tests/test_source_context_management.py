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


if __name__ == "__main__":
    unittest.main()
