"""Guard history-card artwork against repeat fetches and image re-decoding."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class HistoryArtworkCacheTests(unittest.TestCase):
    def test_history_cards_restore_cached_poster_identity_before_refresh(self):
        history = (ROOT / "Vesper/Features/History/HistoryView.swift").read_text()
        loader = history.split("private struct HistoryMediaCard:", 1)[1]
        self.assertLess(loader.index("imageMetadata(key: cacheKey)"),
                        loader.index("detailMetadata(for: entry.item"))
        self.assertIn("resolvedItem = cached.item", loader)
        self.assertIn("posterItem = cached.posterItem", loader)
        self.assertIn("saveImageMetadata(data, key: cacheKey, generation: generation)", loader)
        self.assertIn("guard !Task.isCancelled, cached == nil else { return }", loader)

    def test_artwork_bytes_remain_in_the_disk_image_cache(self):
        thumbnail = (ROOT / "Vesper/Features/Media/MediaThumbnail.swift").read_text()
        cache = (ROOT / "Vesper/Infrastructure/Sources/Caching/AppCacheStore.swift").read_text()
        self.assertIn('await AppCacheStore.shared.image(key: key, ignoringLocalCache: ignoresCache)', thumbnail)
        self.assertIn('await AppCacheStore.shared.saveImage(data, key: key, generation: generation)', thumbnail)
        self.assertNotIn("decodedArtwork", thumbnail)
        self.assertIn("trim(category, limit: (category == .images ? 128 : 32) * 1024 * 1024)", cache)
        self.assertIn("func imageMetadata(key: String)", cache)
        self.assertIn("func saveImageMetadata(_ data: Data, key: String, generation: UUID)", cache)
