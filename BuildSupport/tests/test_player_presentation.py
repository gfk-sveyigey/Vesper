"""Structural guards, not a substitute for on-device animation testing."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
class PlayerPresentationTests(unittest.TestCase):
    def test_detail_anchor_and_menu_groups(self):
        source = (ROOT / 'Vesper/Features/Media/EmbySeriesDetailView.swift').read_text()
        toolbar = source.split('GlassEffectContainer(', 1)[1].split('.sharedBackgroundVisibility(.hidden)', 1)[0]
        self.assertEqual(toolbar.count('.glassEffectID("detailActionAnchor"'), 1)
        self.assertIn('.glassEffectTransition(.matchedGeometry)', toolbar)
        self.assertIn('if !hasScrolled {', toolbar)
        self.assertIn('HStack(spacing: 0) {', toolbar)
        self.assertIn('.padding(.trailing, 12)', toolbar)
        self.assertNotIn('DetailActionFan', source)
        self.assertIn('@State private var hasScrolled = false', source)
        self.assertIn('Image(systemName: hasScrolled ? "ellipsis"', toolbar)
        self.assertIn('.contentTransition(.symbolEffect(.replace))', toolbar)
        self.assertIn('.animation(reduceMotion ? nil : .default, value: hasScrolled)', toolbar)
        self.assertIn('Section { favoriteButton }', toolbar)
        self.assertIn('versionMenu(inMenu: true)', toolbar)
        # Toolbar icons must not turn into menu text while collapsing.
        self.assertIn('versionMenu().frame(width: 44', toolbar)
        self.assertNotIn('if hasScrolled { Label', source)
        self.assertIn('.glassEffect(.regular, in: .circle)', toolbar)
    def test_progress_time_format_and_remaining_preference(self):
        player = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        settings = (ROOT / 'Vesper/Features/Settings/PlaybackSettingsView.swift').read_text()
        time_label = player.split('private func timeLabel', 1)[1].split('\n}', 1)[0]
        self.assertIn('String(format: "%d:%02d", value / 60, value % 60)', time_label)
        self.assertNotIn('value / 3600', time_label)
        self.assertIn('Text(timeLabel(PlaybackPreferences.showsRemainingDuration', player)
        self.assertIn('max(0, session.duration - (isScrubbing ? scrubTime : session.currentTime))', player)
        self.assertIn('@AppStorage("player.showsRemainingDuration")', settings)
        self.assertIn('Toggle("显示剩余时长", isOn: $showsRemainingDuration)', settings)
    def test_progress_glass_group_and_scrub_controls(self):
        source = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        bottom = source.split('private func bottomControls', 1)[1].split('private var progressBar', 1)[0]
        self.assertIn('progressRow', bottom)
        self.assertIn('.glassEffect(.regular, in: Capsule())', bottom)
        self.assertIn('if !isScrubbing {', bottom)
        self.assertIn('bottomActions(landscape: landscape)', bottom)
        self.assertIn('progressRow', source.split('if isScrubbing && !controlsVisible {', 1)[1].split('if regionsVisible', 1)[0])
        self.assertIn('finishScrubbing(commit: scrubPreviews)', source)
        self.assertIn('phase == .ended', source)
    def test_sources_are_tunable_transparent_rows(self):
        source = (ROOT / 'Vesper/Features/Sources/SourcesView.swift').read_text()
        media = (ROOT / 'Vesper/Features/Media/MediaView.swift').read_text()
        settings = (ROOT / 'Vesper/Features/Settings/SettingsView.swift').read_text()
        row = source.split('private struct SourceListRow', 1)[1]
        self.assertIn('.frame(height: rowHeight, alignment: .center)', row)
        self.assertIn('private var iconSide:', row)
        self.assertIn('rowHeight - iconTop - iconBottom', row)
        self.assertIn('VesperTheme.accent(accent)', row)
        self.assertNotIn('.background(Color(uiColor: .secondarySystemBackground)', row)
        for metric in ['sourceListRowHeight', 'sourceListIconTop', 'sourceListIconLeading',
                       'sourceListIconBottom', 'sourceListIconTrailing']:
            self.assertIn(metric, media)
            self.assertIn('.' + metric, settings)
        self.assertIn('sourceSummary(for: source)', row)
        self.assertIn('movieCount', row)
        self.assertIn('seriesCount', row)
        self.assertIn('lastPlayed', row)
    def test_rotation_sync_lifecycle(self):
        source = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        controller = source.split('final class PlayerVideoSurfaceController', 1)[1]
        self.assertIn('CADisplayLink(target: RotationGeometryTick', controller)
        self.assertIn('link.add(to: .main, forMode: .common)', controller)
        self.assertIn('weak var owner: PlayerVideoSurfaceController?', controller)
        self.assertIn('override func viewDidDisappear', controller)
        self.assertIn('return isVideo || !descendants.isEmpty ? [layer] + descendants : []', controller)
        self.assertLess(controller.index('let visible = layer.presentation()'), controller.index('// Capture presentation geometry'))
        self.assertIn('guard let self, self.rotationRevision == revision', controller)
