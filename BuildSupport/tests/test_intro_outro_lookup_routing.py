from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class IntroOutroLookupRoutingTests(unittest.TestCase):
    def test_lookup_is_owned_by_playback_session(self):
        detail = (ROOT / "Vesper/Features/Media/EmbySeriesDetailView.swift").read_text()
        playback = (ROOT / "Vesper/Infrastructure/Playback/PlaybackSession.swift").read_text()

        self.assertNotIn("EmbySkipLookup.shared", detail)
        self.assertIn("EmbySkipLookup.shared.markers(for: target", playback)


if __name__ == "__main__":
    unittest.main()
