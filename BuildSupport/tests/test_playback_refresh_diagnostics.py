from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PlaybackRefreshDiagnosticsTests(unittest.TestCase):
    def test_aether_background_failure_recovers_without_engine_failover(self):
        core = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackCore.swift').read_text()
        session = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackSession.swift').read_text()
        self.assertIn('aetherBackgroundRecoveryPending', core)
        self.assertIn('self.snapshot.requiresForegroundReload = true', core)
        self.assertIn('等待前台重载', core)
        self.assertIn('var requestedAutoplay: Bool { configuration.autoplay }', core)
        recovery = session.split('private func restoreReleasedAetherSession', 1)[1].split('private func recordPlaybackHistory', 1)[0]
        self.assertIn('core.snapshot.requiresForegroundReload', recovery)
        self.assertIn('engine: .aether', recovery)
        self.assertIn('restoreReleasedAetherSession(resume: core.requestedAutoplay)', session)

    def test_vlc_resume_preserves_the_full_input_timeline(self):
        driver = (ROOT / 'Playback/VLCBridge/VLCDriver.swift').read_text()
        self.assertNotIn('media.addOption(":start-time=', driver)
        self.assertIn('!configuration.autoplay || configuration.position > 0', driver)
        self.assertIn('guard player.isSeekable else', driver)
        self.assertIn('try player.seek(to: .seconds(configuration.position), fast: false)', driver)
        self.assertIn('var didRestorePosition = false', driver)
        self.assertIn('if player.isPlaying && pendingSeekTime == nil { return }', driver)
        self.assertIn('if isOpeningMedia, player.state != .error { result.phase = .loading }', driver)
        self.assertIn('if !isOpeningMedia, Date() >= seekClockDeadline', driver)

    def test_subtitle_selection_survives_vlc_async_track_acknowledgement(self):
        core = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackCore.swift').read_text()
        session = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackSession.swift').read_text()
        vlc = (ROOT / 'Playback/VLCBridge/VLCDriver.swift').read_text()
        self.assertIn('subtitleIntent = .track(track)', core)
        self.assertIn('target?.selected == true', core)
        self.assertIn('core.carriedTrackIntents()', session)
        self.assertIn('let subtitleTarget = core.restoringSubtitleID', session)
        self.assertIn('guard let track = player.subtitleTracks.first(where: { $0.id == requestedID }) else { return }', vlc)
        self.assertIn('let track = player.audioTracks.first(where: { $0.id == id }) else { return }', vlc)

    def test_vlc_uses_cjk_subtitle_font_and_matches_emby_preference(self):
        vlc = (ROOT / 'Playback/VLCBridge/VLCDriver.swift').read_text()
        core = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackCore.swift').read_text()
        self.assertIn('--freetype-font=PingFang SC', vlc)
        self.assertIn('Player(instance: instance)', vlc)
        self.assertIn('instance.logStream(minimumLevel: .notice)', vlc)
        self.assertNotIn('media.addOption(":freetype-font=', vlc)
        self.assertIn('let script = chineseScript(old)', core)
        self.assertIn('tracks[ordinal]', core)

    def test_timeline_does_not_broadcast_through_shared_session(self):
        session = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackSession.swift').read_text()
        screen = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        self.assertIn('@MainActor @Observable', session)
        self.assertIn('let timeline = PlaybackTimelineState()', session)
        for field in ('currentTime', 'bufferedTime', 'bufferedRanges', 'downloadBytesPerSecond'):
            self.assertNotIn('@Published private(set) var ' + field, session)
        self.assertIn('PlayerTimelineRegion { progressRowContent }', screen)
        self.assertIn('PlayerTimelineRegion { Text(verbatim: session.downloadSpeedText) }', screen)
        self.assertIn('lastNowPlayingPosition', session)

    def test_removed_refresh_and_image_cache_debug_overrides_stay_removed(self):
        sources = [
            path.read_text()
            for path in (ROOT / 'Vesper').rglob('*.swift')
        ]
        combined = "\n".join(sources)
        self.assertNotIn('ImageCacheDebugSettings', combined)
        self.assertNotIn('ignoringLocalCache', combined)
        self.assertNotIn('throttleHiddenPausedPolling', combined)
        self.assertNotIn('detachHiddenVideoSurface', combined)
        self.assertIn('Task.sleep(for: .milliseconds(150))', combined)

    def test_unchanged_engine_snapshots_do_not_publish_ui_updates(self):
        core = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackCore.swift').read_text()
        poll = core.split('private func poll(generation:', 1)[1].split('func waitUntilRetired()', 1)[0]
        self.assertIn('needsStateNotification(from: previous, to: self.snapshot)', poll)
        self.assertIn('old.phase != new.phase', core)
        self.assertIn('old.subtitleImage !== new.subtitleImage', core)
        session = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackSession.swift').read_text()
        self.assertIn('if abs(currentTime - nextTime) > 0.01 { currentTime = nextTime }', session)


if __name__ == '__main__':
    unittest.main()
