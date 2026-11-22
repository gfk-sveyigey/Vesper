from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PlaybackRefreshDiagnosticsTests(unittest.TestCase):
    def test_history_persistence_has_first_write_diagnostics(self):
        session = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackSession.swift').read_text()
        persistence = session.split('private func persistHistory()', 1)[1].split('/// Reconcile', 1)[0]
        self.assertIn('开始首次历史写入', persistence)
        self.assertIn('首次历史写入完成', persistence)
        self.assertIn('JSONEncoder().encode(history)', persistence)

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
        self.assertIn('else if configuration.position > 0 { try player.play() }', driver)

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

    def test_video_surface_can_be_detached_independently(self):
        navigation = (ROOT / 'Vesper/Features/Navigation/AppNavigationView.swift').read_text()
        settings = (ROOT / 'Vesper/Features/Settings/SettingsView.swift').read_text()
        core = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackCore.swift').read_text()
        self.assertIn('!detachHiddenVideoSurface', navigation)
        self.assertIn('debug.playback.detachHiddenVideoSurface', core)
        self.assertIn('隐藏播放器时卸载视频画面', settings)

    def test_hidden_paused_polling_can_be_throttled_independently(self):
        core = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackCore.swift').read_text()
        session = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackSession.swift').read_text()
        settings = (ROOT / 'Vesper/Features/Settings/SettingsView.swift').read_text()
        self.assertIn('debug.playback.throttleHiddenPausedPolling', core)
        self.assertIn('!self.isPlayerPresented && self.snapshot.phase == .paused', core)
        self.assertIn('try await Task.sleep(for: .seconds(1))', core)
        self.assertIn('didSet { core.isPlayerPresented = isPresented }', session)
        self.assertIn('隐藏且暂停时将状态轮询降至 1 Hz', settings)

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
