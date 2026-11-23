from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PlaybackRecordSemanticsTests(unittest.TestCase):
    def test_mark_unplayed_does_not_clear_resume_progress(self):
        source = (ROOT / "Vesper/Infrastructure/Playback/PlaybackSession.swift").read_text()
        change = source.split("func setPlayed(_ played:", 1)[1].split("private func submitPlayed", 1)[0]
        self.assertNotIn("clearSavedProgress", change)
        self.assertNotIn("shouldClearProgress", change)

    def test_clear_progress_deletes_history_but_persists_local_watched_state(self):
        source = (ROOT / "Vesper/Infrastructure/Playback/PlaybackSession.swift").read_text()
        clear = source.split("func clearProgress(for item:", 1)[1].split("@Published private var favoriteStates", 1)[0]
        self.assertIn("clearSavedProgress(for: item, removeFromHistory: true)", clear)
        self.assertIn("localPlayedStates", source)
        self.assertIn('"player.localPlayedStates.v1"', source)

    def test_emby_clear_progress_maps_to_mark_unplayed(self):
        source = (ROOT / "Vesper/Infrastructure/Sources/EmbyIntegration.swift").read_text()
        clear = source.split("func clearProgress(for item:", 1)[1].split("private func userActionClient", 1)[0]
        self.assertIn("setPlayed(false, for: item, source: source)", clear)
        self.assertNotIn("PlaybackPositionTicks", clear)


if __name__ == "__main__":
    unittest.main()
