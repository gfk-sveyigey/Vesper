import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class HeadphoneSpatialAudioTests(unittest.TestCase):
    def test_default_on_preference_reaches_both_engines(self):
        settings = (ROOT / 'Vesper/Features/Settings/PlaybackSettingsView.swift').read_text()
        contracts = (ROOT / 'Playback/Contracts/PlaybackContracts.swift').read_text()
        session = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackSession.swift').read_text()
        aether = (ROOT / 'Playback/AetherBridge/AetherDriver.swift').read_text()
        vlc = (ROOT / 'Playback/VLCBridge/VLCDriver.swift').read_text()
        self.assertIn('private var headphoneSpatialAudio = true', settings)
        self.assertIn('Toggle("耳机空间音效", isOn: $headphoneSpatialAudio)', settings)
        self.assertIn('public var headphoneSpatialAudio = true', contracts)
        self.assertIn('value.headphoneSpatialAudio = PlaybackPreferences.headphoneSpatialAudio', session)
        self.assertIn('AudioShaping(binaural: configuration.headphoneSpatialAudio)', aether)
        self.assertIn('configuration.headphoneSpatialAudio ? .binaural : .unset', vlc)

    def test_aetherengine_is_pinned_to_latest_release_tag(self):
        project = (ROOT / 'Vesper.xcodeproj/project.pbxproj').read_text()
        self.assertIn('requirement = { kind = exactVersion; version = 7.76.0; };', project)

    def test_setting_and_footer_are_localized_in_all_supported_languages(self):
        locales = ('de', 'en', 'es', 'fr', 'ja', 'ko', 'zh-Hans', 'zh-Hant')
        label = '"耳机空间音效"'
        footer = '"将多声道音频处理为空间感耳机立体声；单声道和立体声保持不变，效果取决于当前播放引擎路径。"'
        for locale in locales:
            strings = (ROOT / f'Vesper/Resources/{locale}.lproj/Localizable.strings').read_text()
            self.assertIn(label, strings, locale)
            self.assertIn(footer, strings, locale)


if __name__ == '__main__':
    unittest.main()
