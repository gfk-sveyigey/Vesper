"""Guard the open-source dependency list and license links."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PlaybackLicensesPageTests(unittest.TestCase):
    def test_lists_dependencies_with_versions_licenses_and_project_links(self):
        source = (ROOT / "Vesper/Features/Settings/PlaybackLicensesView.swift").read_text()
        for name in ("AetherEngine", "FFmpeg", "dav1d", "zimg", "zvbi", "LibDovi", "SwiftVLC", "libVLC"):
            self.assertIn(f'name: "{name}"', source)
        self.assertIn("let version: String", source)
        self.assertIn("let license: String", source)
        self.assertIn("Link(destination: dependency.url)", source)
        self.assertIn("AetherEngine-LICENSE", source)
        self.assertIn("SwiftVLC-LICENSE", source)
        self.assertIn("FFmpeg-LICENSE", source)
        self.assertIn("zvbi-LICENSE", source)
        self.assertIn("LibDovi-LICENSE", source)
        self.assertNotIn("播放框架与依赖声明", source)
        self.assertIn("dependencies.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }", source)


if __name__ == "__main__":
    unittest.main()
