"""Structural guards, not a substitute for on-device animation testing."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
class PlayerPresentationTests(unittest.TestCase):
    def test_detail_anchor_and_menu_groups(self):
        source = (ROOT / 'Vesper/Features/Media/EmbySeriesDetailView.swift').read_text()
        toolbar = source.split('private var detailToolbar:', 1)[1].split('private func toggleFavorite()', 1)[0]
        self.assertEqual(toolbar.count('.glassEffectID("tracks"'), 1)
        self.assertEqual(toolbar.count('.glassEffectID("primary"'), 1)
        self.assertIn('.glassEffectTransition(.matchedGeometry)', toolbar)
        self.assertIn('if !hasScrolled {', toolbar)
        self.assertIn('HStack(spacing: 0) {', toolbar)
        self.assertIn('.offset(x: -56)', toolbar)
        self.assertNotIn('DetailActionFan', source)
        self.assertIn('@State private var hasScrolled = false', source)
        self.assertIn('Image(systemName: hasScrolled ? "ellipsis"', toolbar)
        self.assertIn('.contentTransition(.symbolEffect(.replace))', toolbar)
        self.assertIn('.animation(reduceMotion ? nil : .snappy(duration: 0.3), value: hasScrolled)', toolbar)
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
        self.assertIn('.frame(height: 56.0 * 2 / 3)', bottom)
        self.assertIn('.scaleEffect(isScrubbing ? 1.06 : 1)', bottom)
        self.assertIn('.allowsHitTesting(showsOtherControls)', bottom)
        self.assertIn('bottomActions(landscape: landscape)', bottom)
        self.assertNotIn('if isScrubbing && !controlsVisible {', source)
        self.assertIn('finishScrubbing(commit: scrubPreviews)', source)
        self.assertIn('phase == .ended', source)
    def test_sources_are_tunable_transparent_rows(self):
        source = (ROOT / 'Vesper/Features/Sources/SourcesView.swift').read_text()
        media = (ROOT / 'Vesper/Features/Media/MediaView.swift').read_text()
        settings = (ROOT / 'Vesper/Features/Media/MediaView.swift').read_text()
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

    def test_video_render_area_tracks_centered_content_bounds(self):
        contracts = (ROOT / 'Playback/Contracts/PlaybackContracts.swift').read_text()
        player = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        session = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackSession.swift').read_text()
        layout = contracts.split('public enum VideoViewportLayout', 1)[1].split('public struct EngineConfiguration', 1)[0]
        controller = player.split('final class PlayerVideoSurfaceController', 1)[1]

        self.assertIn('min(viewport.width / sourceSize.width, viewport.height / sourceSize.height)', layout)
        self.assertIn('viewport.midX - size.width / 2', layout)
        self.assertIn('guard !fillsScreen', layout)
        self.assertIn('PlayerVideoSurface(videoView: view, videoSize: session.videoSize', player)
        self.assertIn('fillsScreen: session.fillsScreen', player)
        self.assertIn('renderingView.centerXAnchor.constraint(equalTo: view.centerXAnchor)', controller)
        self.assertIn('renderingView.centerYAnchor.constraint(equalTo: view.centerYAnchor)', controller)
        self.assertIn('VideoViewportLayout.contentRect(', controller)
        self.assertIn('info.hasVideo, info.width > 0, info.height > 0', session)

    def test_hidden_pip_surface_keeps_full_host_layout(self):
        navigation = (ROOT / "Vesper/Features/Navigation/AppNavigationView.swift").read_text()
        self.assertIn("PlayerVideoSurface(videoView: view, videoSize: nil, fillsScreen: false)", navigation)
