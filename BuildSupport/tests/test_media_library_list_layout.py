from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MediaLibraryListLayoutTests(unittest.TestCase):
    def test_row_has_requested_metadata_and_tunable_geometry(self):
        source = (ROOT / "Vesper/Features/Media/MediaView.swift").read_text()
        settings = (ROOT / "Vesper/Features/Settings/SettingsView.swift").read_text()
        row = source.split("private func libraryRow(", 1)[1].split("private var detailOrigin", 1)[0]
        for metric in (
            "browserListRowHeight",
            "browserListImageTop",
            "browserListImageLeading",
            "browserListImageBottom",
            "browserListImageTrailing",
        ):
            self.assertIn(metric, source)
            self.assertIn(metric, settings)
        self.assertIn("Text(verbatim: item.title)", row)
        self.assertIn("let details = [kind, genres]", row)
        self.assertIn("let yearAndRating = [year, rating", row)
        self.assertNotIn("item.embyPresentation?.overview", row)


if __name__ == "__main__":
    unittest.main()
