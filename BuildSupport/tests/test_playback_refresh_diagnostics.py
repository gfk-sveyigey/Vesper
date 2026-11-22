from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PlaybackRefreshDiagnosticsTests(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
