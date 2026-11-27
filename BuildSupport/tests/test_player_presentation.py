"""Structural guards, not a substitute for on-device animation testing."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
class PlayerPresentationTests(unittest.TestCase):
    def test_subtitle_menu_exposes_engine_specific_style_panel(self):
        player = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        settings = (ROOT / 'Vesper/Features/Settings/PlaybackSettingsView.swift').read_text()
        subtitle_menu = player.split('private func subtitleMenu()', 1)[1].split('private func audioMenu()', 1)[0]
        self.assertIn('字幕样式', subtitle_menu)
        self.assertIn('requestPanel(.subtitles)', subtitle_menu)
        self.assertIn('session.currentEngine == .vlc', settings)
        self.assertIn('session.setSubtitleDelay($0)', settings)
        self.assertIn('session.setSubtitleSize($0)', settings)
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
        self.assertIn('.frame(height: 44)', bottom.split('.glassEffect(controlGlass, in: Capsule())', 1)[0])
        self.assertIn('.glassEffect(controlGlass, in: Capsule())', bottom)
        self.assertIn('.scaleEffect(scrubSource == .timeline ? 1.06 : 1)', bottom)
        self.assertIn('recognizer.minimumPressDuration = 0', source)
        layer = source.split('bottomControls(landscape: landscape, availableWidth:', 1)[1].split('}', 1)[0]
        self.assertIn('.opacity(controlsVisible ? 1 : 0)', layer)
        self.assertIn('.allowsHitTesting(controlsVisible)', layer)
        self.assertIn('.accessibilityHidden(!controlsVisible)', layer)
        self.assertNotIn('scrubShowsControls', layer)
        self.assertNotIn('usesCompactProgress', source)
        self.assertNotIn('progressCapsule', source)
        self.assertIn('beginScrubbing(.surface)', source)
        self.assertNotIn('showsOtherControls', bottom)
        self.assertIn('bottomActions(landscape: landscape, availableWidth: availableWidth)', bottom)
        self.assertNotIn('if isScrubbing && !controlsVisible {', source)
        self.assertIn('finishScrubbing(commit: false)', source)
        self.assertIn('phase == .ended', source)

    def test_more_controls_share_button_size_and_slide_with_the_timeline(self):
        source = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        settings = (ROOT / 'Vesper/Features/Settings/PlaybackSettingsView.swift').read_text()
        actions = source.split('private func bottomActions(', 1)[1].split('private func landscapeMenu(', 1)[0]
        left_group = actions.split('.glassEffect', 1)[0]
        self.assertIn('bottomAction("详细信息"', left_group)
        self.assertIn('bottomAction("显示调试信息"', left_group)
        self.assertNotIn('视频简介', actions)
        self.assertIn('bottomButtonSize: CGFloat = 44', source)
        self.assertIn('Toggle("常显更多控制按钮"', settings)
        self.assertIn('private var alwaysShowsMoreControls = false', settings)
        self.assertIn('private var alwaysShowsMoreControls = false', source)
        self.assertIn('alwaysShowsMoreControls || moreControlsExpanded', source)
        self.assertIn('.offset(y: showsMoreControls ? 0 : bottomButtonSize + bottomControlSpacing)', source)
        self.assertIn('.allowsHitTesting(showsMoreControls)', source)
        self.assertIn('controlsVisible && !alwaysShowsMoreControls', source)
        self.assertIn('setMoreControlsExpanded(kind == .up)', source)
        self.assertIn('if !visible { moreControlsExpanded = false }', source)

    def test_player_edge_spacing_is_four_independent_values(self):
        source = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        settings = (ROOT / 'Vesper/Features/Settings/DebugSettingsView.swift').read_text()
        peripheral = source.split('private func peripheralControls(', 1)[1].split('private var audioIsMuted', 1)[0]
        diagnostics = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackCore.swift').read_text()
        keys = [
            ('controlTopPortraitSpacingKey', '竖屏顶部间距', 'topPortraitSpacing'),
            ('controlTopLandscapeSpacingKey', '横屏顶部间距', 'topLandscapeSpacing'),
            ('controlBottomPortraitSpacingKey', '竖屏底部间距', 'bottomPortraitSpacing'),
            ('controlBottomLandscapeSpacingKey', '横屏底部间距', 'bottomLandscapeSpacing'),
        ]
        for key, label, property_name in keys:
            self.assertIn(key, diagnostics)
            self.assertIn(f'@AppStorage(PlaybackDiagnostics.{key}) private var {property_name}', settings)
            self.assertIn(f'@AppStorage(PlaybackDiagnostics.{key}) private var {property_name}', source)
            self.assertIn(f'controlEdgeSpacingStepper("{label}"', settings)
        self.assertIn('defaultControlTopPortraitSpacing = 0', diagnostics)
        self.assertIn('defaultControlTopLandscapeSpacing = 24', diagnostics)
        self.assertIn('defaultControlBottomPortraitSpacing = 35', diagnostics)
        self.assertIn('defaultControlBottomLandscapeSpacing = 24', diagnostics)
        self.assertIn('topLandscapeSpacing : topPortraitSpacing', source)
        self.assertIn('bottomLandscapeSpacing : bottomPortraitSpacing', source)
        self.assertIn('.padding(.top, topInset)', peripheral)
        self.assertIn('.padding(.bottom, bottomInset)', peripheral)
        self.assertIn('bottomControls(landscape: landscape, availableWidth: availableWidth,', peripheral)
        self.assertNotIn('controlEdgeSpacingKey', diagnostics)

    def test_debug_interface_layout_is_split_into_scoped_groups(self):
        source = (ROOT / 'Vesper/Features/Settings/DebugSettingsView.swift').read_text()
        self.assertIn('DebugSettingsSection(title: "播放器控制区")', source)
        self.assertIn('DebugSettingsSection(title: "媒体卡片布局")', source)
        self.assertIn('DebugSettingsSection(title: "媒体列表布局")', source)
        self.assertIn('DebugSettingsSection(title: "来源列表布局")', source)
        self.assertIn('layout.reset(Self.mediaCardMetrics)', source)
        self.assertIn('layout.reset(Self.browserListMetrics)', source)
        self.assertIn('layout.reset(Self.sourceListMetrics)', source)
        self.assertIn('layout.reset(Self.headerMetrics)', source)
        self.assertIn('layout.reset(Self.carouselBlurMetrics)', source)
        self.assertNotIn('interfaceMetrics', source)

    def test_player_backdrop_and_glass_are_configurable(self):
        source = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        settings = (ROOT / 'Vesper/Features/Settings/DebugSettingsView.swift').read_text()
        diagnostics = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackCore.swift').read_text()
        self.assertIn('defaultControlScrimOpacity = 25', diagnostics)
        self.assertIn('controlScrimOpacityRange = 0...100', diagnostics)
        for text in (source, settings):
            self.assertIn('@AppStorage(PlaybackDiagnostics.controlScrimOpacityKey)', text)
            self.assertIn('@AppStorage(PlaybackDiagnostics.controlGlassClearKey) private var controlGlassClear = false', text)
        self.assertIn('Color.black.opacity(controlScrimOpacity)', source)
        self.assertNotIn('LinearGradient', source)
        self.assertIn('controlGlassClear ? .clear : .regular', source)
        self.assertIn('.glassEffect(controlGlass.interactive(), in: Circle())', source)
        self.assertNotIn('.glassEffect(.regular', source)

    def test_scrub_preview_does_not_seek_or_change_control_visibility(self):
        source = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        scrubbing = source.split('private func beginScrubbing(', 1)[1].split('private func handleTap(', 1)[0]
        preview, finish = scrubbing.split('private func finishScrubbing(', 1)
        self.assertIn('await session.scrubPreview(at: target)', preview)
        self.assertIn('if scrubTime == target, let image { scrubImage = image }', preview)
        self.assertNotIn('session.seek', preview)
        self.assertEqual(finish.count('session.seekManually('), 1)
        self.assertIn('session.resumeAfterCancelledScrub()', finish)
        self.assertNotIn('revealControls()', scrubbing)
        self.assertNotIn('setControlsVisible(', scrubbing)
        self.assertIn('Task.sleep(for: .milliseconds(250))', source)

    def test_scrub_preview_covers_video_and_waits_for_the_new_picture(self):
        source = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        layers = source.split('private func videoLayers(', 1)[1].split('private func beginScrubbing(', 1)[0]
        handoff = source.split('private func waitForScrubHandoff()', 1)[1].split('private func handleTap(', 1)[0]
        self.assertLess(layers.index('PlayerVideoSurface('), layers.index('Image(uiImage: scrubImage)'))
        self.assertIn('VideoViewportLayout.contentRect(', layers)
        self.assertIn('aspectRatio(contentMode: session.fillsScreen ? .fill : .fit)', layers)
        self.assertNotIn('scrubPreviewImage', source)
        self.assertIn('shouldSeek && scrubImage != nil', handoff)
        self.assertIn('if !session.isSeeking && !session.isLoading', handoff)
        self.assertIn('if marker != initial { break }', handoff)
        self.assertIn('clock.now < deadline', handoff)
        self.assertIn('if !keepPreview { clearScrubPreview() }', handoff)

    def test_timeline_drag_is_relative_to_starting_playback_position(self):
        source = (ROOT / 'Vesper/Features/Player/PlayerScreen.swift').read_text()
        gesture = source.split('.gesture(PlayerTimelinePress', 1)[1].split('.accessibilityAdjustableAction', 1)[0]
        self.assertIn('recognizer.location(in: recognizer.view?.window).x', source)
        self.assertIn('timelineDragOrigin = (x, max(geometry.size.width, 1))', gesture)
        self.assertIn('let distance = x - origin.x', gesture)
        self.assertIn('updateScrubbing(scrubStart + Double(distance / origin.width) * session.duration)', gesture)
        self.assertIn('finishScrubbing(commit: scrubTime != scrubStart)', gesture)
        self.assertNotIn('updateScrubbing(Double(x /', gesture)

    def test_precise_seek_preference_applies_to_manual_jumps(self):
        settings = (ROOT / 'Vesper/Features/Settings/PlaybackSettingsView.swift').read_text()
        session = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackSession.swift').read_text()
        aether = (ROOT / 'Playback/AetherBridge/AetherDriver.swift').read_text()
        vlc = (ROOT / 'Playback/VLCBridge/VLCDriver.swift').read_text()
        self.assertIn('private var preciseSeeking = false', settings)
        self.assertIn('Toggle("精准定位", isOn: $preciseSeeking)', settings)
        self.assertIn('fast: !PlaybackPreferences.preciseSeeking', session)
        self.assertIn('resume: Bool? = nil, fast: Bool = false', session)
        self.assertIn('exact: !fast', aether)
        self.assertIn('player.seek(to: .seconds(seconds), fast: fast)', vlc)
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
