import SwiftUI
import UIKit

private enum PlayerPanel: String, Identifiable {
    case queue, gestures, danmaku, subtitles, synopsis, details, more
    var id: String { rawValue }
}

struct PlayerScreen: View {
    @ObservedObject var session: PlaybackSession
    @StateObject private var volume = PlayerSystemVolume()
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var controlsVisible = false
    @State private var autoHideRevision = 0
    @State private var volumeExpanded = false
    @State private var volumeResetRevision = 0
    @State private var volumeDragStart: Float?
    @State private var menuPresented = false
    @State private var scrubShowsControls = true
    @State private var scrubPreviews = true
    @AppStorage("player.subtitle.fontSize") private var subtitleFontSize = 22.0
    @AppStorage("player.subtitle.background") private var subtitleBackground = true
    @State private var scrubTime: Double = 0
    @State private var scrubStart: Double = 0
    @State private var isScrubbing = false
    @State private var resumeAfterScrub = false
    @State private var lastPreview = Date.distantPast
    @State private var panel: PlayerPanel?
    @State private var pendingPanel: PlayerPanel?
    @State private var pendingRotation: Bool?
    @State private var gestureAction = PlayerGestureAction.none
    @State private var gestureStart: Double = 0
    @State private var regionsVisible = false
    @State private var activeRegionCount = 3
    @State private var regionRevision = 0
    @State private var originalBrightness: CGFloat?
    @State private var brightnessScreen: UIScreen?
    @State private var hudText = ""
    @State private var hudSymbol = ""
    @State private var hudDetail = ""
    @State private var hudRevision = 0
    @State private var rotationError: String?
    @State private var showingNotice = false

    private var canAutoHide: Bool {
        controlsVisible && session.isPlaying && !session.isLoading && !session.isSeeking
            && !isScrubbing && !volumeExpanded && volumeDragStart == nil && !menuPresented && panel == nil && !voiceOver && session.errorMessage == nil
    }
    private var screen: UIScreen? { session.videoView?.window?.windowScene?.screen }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                if let view = session.videoView {
                    PlayerVideoSurface(videoView: view, isActive: session.isPresented)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                PlayerGestureSurface(tapped: handleTap, held: { region, fingers in
                    guard !regionsVisible, !controlsVisible, !menuPresented, panel == nil else { return }
                    performGestureAction(PlayerGesturePreferences.action(.longPress, region, fingers))
                }, panned: handlePan)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                subtitles
                    .allowsHitTesting(false)
                LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.75)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(false)
                // Independent placement keeps the transport centered on the
                // actual video, regardless of header/title/progress height.
                transportControls
                    .position(x: (geometry.size.width + geometry.safeAreaInsets.trailing - geometry.safeAreaInsets.leading) / 2,
                              y: (geometry.size.height + geometry.safeAreaInsets.bottom - geometry.safeAreaInsets.top) / 2)
                    .opacity(controlsVisible && session.errorMessage == nil && !session.isLoading ? 1 : 0)
                    .allowsHitTesting(controlsVisible && session.errorMessage == nil && !session.isLoading)
                    .accessibilityHidden(!controlsVisible || session.errorMessage != nil || session.isLoading)
                VStack {
                    topControls(availableWidth: geometry.size.width - (geometry.size.width > geometry.size.height ? 24 : 40), landscape: geometry.size.width > geometry.size.height)
                    Spacer(minLength: 0)
                    bottomControls(landscape: geometry.size.width > geometry.size.height)
                }
                .padding(.horizontal, geometry.size.width > geometry.size.height ? 12 : 20)
                .padding(.vertical, 12)
                // Keep the Menu mounted while fading the controls, so a
                // system menu never loses its presentation anchor mid-use.
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .accessibilityHidden(!controlsVisible)
                if (session.isLoading || session.isSeeking) && !isScrubbing {
                    ProgressView().controlSize(.large).tint(.white)
                        .allowsHitTesting(false).accessibilityLabel("正在加载")
                }
                if !hudText.isEmpty {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: hudSymbol)
                            Text(verbatim: hudText).fontWeight(.semibold)
                            if !hudDetail.isEmpty {
                                Text(verbatim: hudDetail).foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.top, controlsVisible ? 62 : 8)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
                if isScrubbing && !controlsVisible {
                    VStack {
                        Spacer()
                        progressRow
                    }
                    .padding(.horizontal, 28).padding(.bottom, 12)
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
                if regionsVisible { regionOverlay.ignoresSafeArea() }
                if let message = session.errorMessage { errorContent(message) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white).tint(.white)
        }
        .overlay(alignment: .topLeading) {
            PlayerVolumeBridge(volume: volume)
                .frame(width: 160, height: 44)
                .accessibilityHidden(true)
        }
        .background {
            PlayerInterfaceRefreshDriver(
                isActive: scenePhase == .active && session.isPresented
                    && (controlsVisible || menuPresented || panel != nil || showingNotice || regionsVisible || !hudText.isEmpty),
                context: panel?.rawValue ?? (menuPresented ? "menu" : "controls")
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .visible : .hidden)
        .interactiveDismissDisabled(true)
        .sheet(item: $panel, onDismiss: revealControls) { selected in
            panelContent(selected)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
                .onAppear {
                    if selected == .queue { PlayerQueueDiagnostic.write("sheet.appeared source=\(session.queueSource?.kind.rawValue ?? "none") count=\(session.queue.count)") }
                }
                .onDisappear {
                    if selected == .queue { PlayerQueueDiagnostic.write("sheet.disappeared") }
                }
        }
        .alert("播放器", isPresented: $showingNotice) {
            Button("好", role: .cancel) { session.playbackNotice = nil; rotationError = nil }
        } message: { Text(verbatim: rotationError ?? session.playbackNotice ?? "") }
        .onAppear {
            PlayerOrientationPolicy.update(true, scene: session.videoView?.window?.windowScene)
            session.playerDidAppear()
            brightnessScreen = screen
            originalBrightness = screen?.brightness
            scrubTime = session.currentTime
            setControlsVisible(voiceOver || session.errorMessage != nil)
        }
        .onDisappear {
            if isScrubbing { finishScrubbing(commit: scrubPreviews) }
            if let originalBrightness { brightnessScreen?.brightness = originalBrightness }
        }
        .onChange(of: session.currentTime) { _, time in
            if !isScrubbing { scrubTime = min(time, max(session.duration, 1)) }
        }
        .onChange(of: session.currentItem?.id) { _, _ in
            isScrubbing = false
            scrubTime = 0
            setControlsVisible(voiceOver)
        }
        .onChange(of: session.isPlaying) { _, _ in autoHideRevision += 1 }
        .onChange(of: session.isLoading) { _, _ in autoHideRevision += 1 }
        .onChange(of: session.isSeeking) { _, _ in autoHideRevision += 1 }
        .onChange(of: session.errorMessage) { _, message in if message != nil { revealControls() } }
        .onChange(of: session.playbackNotice) { _, message in if message != nil { showingNotice = true; revealControls() } }
        .onChange(of: volume.value) { old, new in if new > 0.001 && old != new && session.isMuted { session.unmute() } }
        .onChange(of: volumeDragStart) { _, _ in autoHideRevision += 1 }
        .onChange(of: voiceOver) { _, _ in revealControls() }
        .onChange(of: panel) { _, _ in revealControls() }
        .onChange(of: scenePhase) { _, phase in if phase != .active && isScrubbing { finishScrubbing(commit: scrubPreviews) } }
        .task(id: autoHideRevision) {
            guard canAutoHide else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled, canAutoHide else { return }
            setControlsVisible(false)
        }
        .task(id: volumeResetRevision) {
            guard !controlsVisible else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled, !controlsVisible else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { volumeExpanded = false; volumeDragStart = nil }
        }
        .task(id: hudRevision) {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            hudText = ""
        }
    }

    private func topControls(availableWidth: CGFloat, landscape: Bool) -> some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 10) {
                glassButton("关闭", symbol: "xmark", iconSize: 19) { session.stop() }
                HStack(spacing: 16) {
                    Button { revealControls(); session.startPictureInPicture() } label: {
                        Image(systemName: "pip.enter").font(.system(size: 17, weight: .medium))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!session.isPictureInPicturePossible)
                    .accessibilityLabel("画中画")
                    PlayerAirPlayButton().frame(width: 44, height: 44).accessibilityLabel("投屏")
                }
                .glassEffect(.regular.interactive(), in: Capsule())
                Spacer(minLength: 0)
            }
            .opacity(volumeExpanded && !landscape ? 0 : 1)
            .allowsHitTesting(!volumeExpanded || landscape)
            .accessibilityHidden(volumeExpanded && !landscape)
            volumeControl(width: min(240, availableWidth), landscape: landscape)
        }
        .frame(height: 44)
    }

    private var audioIsMuted: Bool { session.isMuted || volume.value <= 0.001 }
    private var displayedVolume: Double { audioIsMuted ? 0 : Double(volume.value) }
    private var volumeSymbol: String {
        if audioIsMuted { return "speaker.slash.fill" }
        if volume.value < 0.34 { return "speaker.wave.1.fill" }
        if volume.value < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
    private func toggleAudioMute() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            if audioIsMuted {
                session.unmute()
                if volume.value <= 0.001 { volume.set(0.1) }
            } else { session.toggleMute() }
        }
    }

    private func volumeControl(width: CGFloat, landscape: Bool) -> some View {
        let expanded = landscape || volumeExpanded
        return ZStack(alignment: .trailing) {
            GeometryReader { geometry in
                let trackWidth = max(0, geometry.size.width - 72)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Rectangle().fill(.white)
                        .frame(width: trackWidth * CGFloat(displayedVolume))
                }
                .frame(width: trackWidth, height: 8).clipShape(Capsule())
                .offset(x: 16)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: audioIsMuted)
            }
            .frame(height: 8)
            .opacity(expanded ? 1 : 0)
            .clipped()
            .allowsHitTesting(false)
            Image(systemName: volumeSymbol)
                .font(.system(size: 17, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .allowsHitTesting(false)
            PlayerVolumeTouchSurface(expanded: expanded, tapped: { onIcon in
                revealControls()
                if !expanded { volumeExpanded = true }
                else if onIcon { toggleAudioMute() }
                else if !landscape { volumeExpanded = false }
            }, dragged: { translation, phase in
                guard expanded else { return }
                if phase == .began {
                    volumeDragStart = volume.value
                }
                guard let start = volumeDragStart else { return }
                session.unmute()
                volume.set(start + Float(translation / max(width - 32, 1)))
                if phase == .ended || phase == .cancelled || phase == .failed {
                    volumeDragStart = nil
                    volume.finishAdjustment(origin: "capsule")
                }
            })
        }
        .frame(width: expanded ? width : 44, height: 44)
        .clipShape(Capsule())
        .glassEffect(.regular.interactive(), in: Capsule())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: expanded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音量")
        .accessibilityValue(Text(verbatim: String(format: "%d%%", Int(displayedVolume * 100))))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            revealControls()
            if landscape { toggleAudioMute() } else { volumeExpanded.toggle() }
        }
        .accessibilityAction(named: Text(audioIsMuted ? "取消静音" : "静音")) { toggleAudioMute() }
        .accessibilityAdjustableAction { direction in
            session.unmute()
            volume.set(volume.value + (direction == .increment ? 0.05 : -0.05))
        }
    }

    private var transportControls: some View {
        HStack(spacing: 32) {
            glassButton("快退", symbol: skipSymbol(backward: true), size: 60) {
                session.seek(to: session.currentTime - PlayerGesturePreferences.skipInterval)
            }.disabled(!session.canSeek)
            glassButton(session.isPlaying ? "暂停" : "播放",
                        symbol: session.isPlaying ? "pause.fill" : "play.fill", size: 88) {
                session.togglePlayback()
            }.disabled(!session.canControl)
            glassButton("快进", symbol: skipSymbol(backward: false), size: 60) {
                session.seek(to: session.currentTime + PlayerGesturePreferences.skipInterval)
            }.disabled(!session.canSeek)
        }
        .fixedSize()
    }

    private func bottomControls(landscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let subtitle = session.currentItem?.subtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                    Text(verbatim: session.currentItem?.title ?? String(localized: "未在播放"))
                        .font(landscape ? .headline : .title3.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if landscape { expandedPlaybackOptions }
                else { playbackOptionsMenu }
            }
            progressRow
            bottomActions(landscape: landscape)
        }
    }

    private var progressRow: some View {
        HStack(spacing: 10) {
            Text(timeLabel(isScrubbing ? scrubTime : session.currentTime))
                .frame(minWidth: 40, alignment: .leading)
            progressBar
            Text(timeLabel(session.duration)).frame(minWidth: 40, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: isScrubbing ? 12 : 8)
                Capsule().fill(.white.opacity(0.35))
                    .frame(height: isScrubbing ? 12 : 8)
                    .frame(maxWidth: .infinity)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geometry.size.width * fraction(session.bufferedTime))
                    }
                Capsule().fill(.white)
                    .frame(height: isScrubbing ? 12 : 8)
                    .frame(maxWidth: .infinity)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geometry.size.width * fraction(isScrubbing ? scrubTime : session.currentTime))
                    }
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard session.canSeek else { return }
                    if !isScrubbing { beginScrubbing() }
                    updateScrubbing(scrubStart + Double(value.translation.width / max(geometry.size.width, 1)) * session.duration)
                }
                .onEnded { value in
                    guard isScrubbing else { return }
                    updateScrubbing(scrubStart + Double(value.translation.width / max(geometry.size.width, 1)) * session.duration)
                    finishScrubbing()
                })
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityValue(timeLabel(isScrubbing ? scrubTime : session.currentTime))
        .accessibilityAdjustableAction { direction in
            session.seek(to: session.currentTime + (direction == .increment ? PlayerGesturePreferences.skipInterval : -PlayerGesturePreferences.skipInterval))
            revealControls()
        }
    }

    private var playbackOptionsMenu: some View {
        PlayerMenuButton(symbol: "ellipsis", accessibilityTitle: VesperLocalization.string("播放选项"),
                         makeMenu: { UIMenu(children: [speedMenu(), audioMenu(), subtitleMenu()]) },
                         visibilityChanged: menuVisibilityChanged)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
    }

    private func speedMenu() -> UIMenu {
        UIMenu(title: VesperLocalization.string("播放速度"), image: UIImage(systemName: "speedometer"), children:
            [Float(0.5), 0.75, 1, 1.25, 1.5, 2].map { rate in
                menuAction(String(format: "%g×", Double(rate)), selected: session.playbackRate == rate) { session.setPlaybackRate(rate) }
            }
        )
    }

    private func subtitleMenu() -> UIMenu {
        var actions = [menuAction(VesperLocalization.string("关闭字幕"), selected: session.selectedSubtitleID == nil) { session.selectSubtitle(nil) }]
        actions += session.subtitleTracks.map { track in
            menuAction(track.name, selected: track.isSelected) { session.selectSubtitle(track.id) }
        }
        if session.subtitleTracks.isEmpty { actions.append(menuAction(VesperLocalization.string("无内嵌字幕"), enabled: false) { }) }
        return UIMenu(title: VesperLocalization.string("字幕"), image: UIImage(systemName: "captions.bubble"), children: actions)
    }

    private func audioMenu() -> UIMenu {
        var actions = session.audioTracks.map { track in
            menuAction(track.name, selected: track.isSelected) { session.selectAudio(track.id) }
        }
        if actions.isEmpty { actions.append(menuAction(VesperLocalization.string("无可用音轨"), enabled: false) { }) }
        return UIMenu(title: VesperLocalization.string("音频"), image: UIImage(systemName: "waveform"), children: actions)
    }

    private var expandedPlaybackOptions: some View {
        HStack(spacing: 16) {
            landscapeMenu("播放速度", symbol: "speedometer", menu: speedMenu)
            landscapeMenu("音频", symbol: "waveform", menu: audioMenu)
            landscapeMenu("字幕", symbol: "captions.bubble", menu: subtitleMenu)
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("播放选项")
        .fixedSize(horizontal: true, vertical: false)
    }

    private func bottomActions(landscape: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 12) {
                compactAction("视频简介", symbol: "text.book.closed") { requestPanel(.synopsis) }
                compactAction("详细信息", symbol: "info.circle") { requestPanel(.details) }
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                compactAction(landscape ? "竖屏" : "横屏", symbol: "rotate.right") { requestRotation(!landscape) }
                compactAction(session.fillsScreen ? "完整显示" : "填满屏幕", symbol: "aspectratio") { session.toggleFill() }
                compactAction("播放列表", symbol: "list.bullet") { requestPanel(.queue) }
                    .disabled(session.queue.isEmpty)
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            PlayerMenuButton(symbol: "gearshape", pointSize: 14, accessibilityTitle: VesperLocalization.string("更多设置"), makeMenu: moreSettingsMenu, visibilityChanged: menuVisibilityChanged)
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: Circle())
        }
    }

    private func compactAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        PlayerActionButton(title: VesperLocalization.string(title), symbol: symbol, pointSize: 14) { revealControls(); action() }
            .frame(width: 36, height: 36)
    }

    private func landscapeMenu(_ title: String, symbol: String, menu: @escaping () -> UIMenu) -> some View {
        PlayerMenuButton(symbol: symbol, accessibilityTitle: VesperLocalization.string(title), makeMenu: menu, visibilityChanged: menuVisibilityChanged)
            .frame(width: 44, height: 44)
    }

    private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        PlayerActionButton(title: VesperLocalization.string(title), symbol: symbol) { revealControls(); action() }
            .frame(width: 44, height: 44)
    }

    private func moreSettingsMenu() -> UIMenu {
        let decoding = UIMenu(title: VesperLocalization.string(session.currentDecoder.title), image: UIImage(systemName: "cpu"), children:
            PlaybackDecoder.allCases.map { decoder in
                UIAction(title: VesperLocalization.string(decoder.title), state: decoder == session.currentDecoder ? .on : .off) { _ in
                    session.setCurrentDecoder(decoder)
                }
            })
        let engineMenu = UIMenu(title: session.currentEngine.title,
                               image: UIImage(systemName: "play.rectangle"), children:
            PlaybackEngine.allCases.map { engine in
                UIAction(title: engine.title, state: engine == session.currentEngine ? .on : .off) { _ in session.setCurrentEngine(engine) }
            })
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: [engineMenu, decoding]),
            UIMenu(options: .displayInline, children: [
                menuAction(VesperLocalization.string("弹幕设置"), symbol: "text.bubble") { requestPanel(.danmaku) },
                menuAction(VesperLocalization.string("字幕设置"), symbol: "textformat.size") { requestPanel(.subtitles) },
                menuAction(VesperLocalization.string("播放手势"), symbol: "hand.draw") { requestPanel(.gestures) }
            ])
        ])
    }

    private func requestPanel(_ selected: PlayerPanel) {
        if selected == .queue {
            PlayerQueueDiagnostic.write("open.request source=\(session.queueSource?.kind.rawValue ?? "none") count=\(session.queue.count)")
        }
        pendingPanel = selected
        if !menuPresented { performMenuNavigation() }
    }

    private func requestRotation(_ landscape: Bool) {
        pendingRotation = landscape
        if !menuPresented { performMenuNavigation() }
    }

    private func menuVisibilityChanged(_ presented: Bool) {
        menuPresented = presented
        revealControls()
        if !presented { performMenuNavigation() }
    }

    private func performMenuNavigation() {
        // Let UIKit commit the menu dismissal, without waiting for its entire
        // animation. Both callback orders (action/end) are supported.
        Task { @MainActor in
            await Task.yield()
            guard !menuPresented else { return }
            if let selected = pendingPanel {
                pendingPanel = nil
                panel = selected
            }
            if let landscape = pendingRotation {
                pendingRotation = nil
                rotate(landscape: landscape)
            }
        }
    }

    private func menuAction(_ title: String, symbol: String? = nil, selected: Bool = false,
                            enabled: Bool = true, action: @escaping () -> Void) -> UIAction {
        UIAction(title: title, image: symbol.flatMap { UIImage(systemName: $0) },
                 attributes: enabled ? [] : .disabled, state: selected ? .on : .off) { _ in
            action()
            revealControls()
        }
    }

    private var subtitles: some View {
        VStack {
            Spacer()
            if let image = session.subtitleImage {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 140)
            }
            if !session.subtitleText.isEmpty {
                Text(verbatim: session.subtitleText)
                    .font(.system(size: subtitleFontSize, weight: .semibold)).multilineTextAlignment(.center)
                    .foregroundStyle(.white).shadow(color: .black, radius: 2, x: 1, y: 1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(subtitleBackground ? 0.45 : 0), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 20).padding(.bottom, controlsVisible ? 178 : (isScrubbing ? 68 : 24))
        .frame(maxWidth: .infinity)
    }

    private func glassButton(_ title: LocalizedStringKey, symbol: String, size: CGFloat = 44, iconSize: CGFloat? = nil,
                             action: @escaping () -> Void) -> some View {
        Button { revealControls(); action() } label: {
            Image(systemName: symbol)
                .font(.system(size: iconSize ?? (size >= 80 ? 36 : (size >= 54 ? 26 : 17)), weight: .medium))
                .frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(Text(title))
    }

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text("无法播放").font(.headline)
            Text(verbatim: message).font(.subheadline).multilineTextAlignment(.center)
            Button("重试") { session.retry(); revealControls() }.buttonStyle(.glass)
        }
        .padding(24).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 30)
    }

    private func panelContent(_ selected: PlayerPanel) -> some View {
        NavigationStack {
            Group {
                switch selected {
                case .more:
                    SettingsPage {
                        SettingsSection {
                            SettingsPicker("播放内核", selection: Binding(get: { session.currentEngine }, set: { session.setCurrentEngine($0) })) {
                                ForEach(PlaybackEngine.allCases) { engine in Text(verbatim: engine.title).tag(engine) }
                            }
                        }
                        SettingsSection {
                            NavigationLink("弹幕设置") { DanmakuSettingsView() }
                            NavigationLink("字幕设置") { SubtitleSettingsView() }
                            NavigationLink("播放手势") { PlayerGestureSettingsView() }
                        }
                    }.contentMargins(.top, 0, for: .scrollContent).navigationTitle("更多设置")
                case .gestures: PlayerGestureSettingsView()
                case .danmaku: DanmakuSettingsView()
                case .subtitles: SubtitleSettingsView()
                case .synopsis: PlayerMediaInfoView(session: session, showsDetails: false)
                case .details: PlayerMediaInfoView(session: session, showsDetails: true)
                case .queue:
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(session.queue) { item in
                                Button { session.playQueued(item); panel = nil } label: {
                                    PlayerQueueRow(session: session, item: item)
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 16)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .contentMargins(.top, 0, for: .scrollContent)
                    .navigationTitle("播放列表")
                }
            }
            .toolbarTitleDisplayMode(.inline)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭", systemImage: "xmark") { panel = nil }.labelStyle(.iconOnly)
            }
        }
    }

    private func beginScrubbing(showControls: Bool = true, previews: Bool = true) {
        guard session.canSeek else { return }
        scrubShowsControls = showControls
        scrubPreviews = previews
        resumeAfterScrub = session.isPlaying
        scrubStart = session.currentTime
        scrubTime = scrubStart
        isScrubbing = true
        lastPreview = .distantPast
        if previews { session.pause() }
        if showControls { revealControls() }
    }
    private func updateScrubbing(_ target: Double) {
        scrubTime = min(session.duration, max(0, target))
        if scrubPreviews && Date().timeIntervalSince(lastPreview) >= 0.15 {
            lastPreview = Date()
            session.seek(to: scrubTime, resume: false)
        }
    }
    private func finishScrubbing(commit: Bool = true) {
        let target = commit ? scrubTime : scrubStart
        isScrubbing = false
        if commit || scrubPreviews { session.seek(to: target, resume: resumeAfterScrub) }
        if scrubShowsControls { revealControls() }
        else { autoHideRevision += 1 }
    }

    private func handleTap(_ region: PlayerGestureRegion, _ fingers: Int, _ double: Bool) {
        guard !menuPresented, panel == nil else { return }
        if regionsVisible { regionsVisible = false; return }
        if controlsVisible {
            // The visible overlay only accepts its buttons and a one-finger
            // background tap to hide. Playback/brightness/volume gestures are
            // reserved for the unobstructed video.
            if !double && fingers == 1 { setControlsVisible(false) }
            return
        }
        activeRegionCount = PlayerGesturePreferences.count(for: double ? .doubleTap : .tap, fingers: fingers)
        let action = PlayerGesturePreferences.action(double ? .doubleTap : .tap, region, fingers)
        performGestureAction(action)
    }

    private func gestureActionLabel(_ action: PlayerGestureAction) -> String {
        switch action {
        case .controls: return "显隐控制层"
        case .play: return "播放"
        case .pause: return "暂停"
        case .showRegions: return "显示区域划分"
        case .playlist: return "播放列表"
        case .synopsis: return "视频简介"
        case .details: return "详细信息"
        case .rotate: return "切换屏幕方向"
        case .fill: return "切换填充方式"
        case .fillScreen: return "填满屏幕"
        case .fitScreen: return "完整显示"
        case .landscape: return "横屏"
        case .portrait: return "竖屏"
        case .pictureInPicture: return "画中画"
        case .close: return "退出播放"
        case .speedUp: return "加快播放速度"
        case .speedDown: return "减慢播放速度"
        case .moreSettings: return "更多设置"
        case .subtitles: return "字幕设置"
        case .danmaku: return "弹幕设置"
        case .gestures: return "播放手势"
        default: return "播放"
        }
    }

    private func performGestureAction(_ action: PlayerGestureAction) {
        if action != .none && action != .controls && ![.backward, .forward, .brightnessUp, .brightnessDown, .volumeUp, .volumeDown].contains(action) {
            let message: String
            switch action {
            case .playback: message = VesperLocalization.string(session.isPlaying ? "暂停" : "播放")
            case .mute: message = VesperLocalization.string(audioIsMuted ? "取消静音" : "静音")
            default: message = VesperLocalization.string(action.rawValue == "controls" ? "显隐控制层" : gestureActionLabel(action))
            }
            showHUD(message, symbol: "checkmark")
        }
        switch action {
        case .none: break
        case .controls: setControlsVisible(!controlsVisible)
        case .playback: session.togglePlayback()
        case .play: if !session.isPlaying { session.togglePlayback() }
        case .pause: session.pause()
        case .backward, .forward:
            guard session.canSeek else { return }
            let start = session.currentTime
            let target = min(session.duration, max(0, start + PlayerGesturePreferences.skipInterval * (action == .backward ? -1 : 1)))
            session.seek(to: target); showSeekHUD(from: start, to: target)
        case .brightnessUp, .brightnessDown:
            if originalBrightness == nil { brightnessScreen = screen; originalBrightness = screen?.brightness }
            let value = min(1, max(0, Double(screen?.brightness ?? 0.5) + (action == .brightnessUp ? 0.1 : -0.1)))
            screen?.brightness = value
            showHUD(String(format: VesperLocalization.string("亮度 %d%%"), Int(value * 100)), symbol: "sun.max.fill")
        case .volumeUp, .volumeDown:
            session.unmute(); volume.set(volume.value + (action == .volumeUp ? 0.1 : -0.1))
            showHUD(String(format: VesperLocalization.string("音量 %d%%"), Int(volume.value * 100)), symbol: "speaker.wave.2.fill")
        case .mute: toggleAudioMute()
        case .showRegions: regionsVisible = true; regionRevision += 1
        case .playlist: requestPanel(.queue)
        case .synopsis: requestPanel(.synopsis)
        case .details: requestPanel(.details)
        case .rotate: requestRotation(!PlayerOrientationPolicy.isLandscape)
        case .fill: session.toggleFill()
        case .fillScreen: if !session.fillsScreen { session.toggleFill() }
        case .fitScreen: if session.fillsScreen { session.toggleFill() }
        case .landscape: requestRotation(true)
        case .portrait: requestRotation(false)
        case .pictureInPicture: session.startPictureInPicture()
        case .close: session.stop()
        case .speedUp, .speedDown:
            let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
            let index = rates.firstIndex(of: session.playbackRate) ?? 2
            session.setPlaybackRate(rates[min(rates.count - 1, max(0, index + (action == .speedUp ? 1 : -1)))])
        case .moreSettings: revealControls(); requestPanel(.more)
        case .subtitles: requestPanel(.subtitles)
        case .danmaku: requestPanel(.danmaku)
        case .gestures: requestPanel(.gestures)
        }
    }

    private func handlePan(_ region: PlayerGestureRegion, _ fingers: Int, _ kind: PlayerGestureKind,
                           _ delta: CGFloat, _ phase: UIGestureRecognizer.State) {
        if phase == .began {
            guard !regionsVisible, !controlsVisible, !menuPresented, panel == nil else { gestureAction = .none; return }
            activeRegionCount = PlayerGesturePreferences.count(for: kind, fingers: fingers)
            gestureAction = PlayerGesturePreferences.action(kind, region, fingers)
            gestureStart = 0
            switch gestureAction {
            case .brightnessUp, .brightnessDown:
                if originalBrightness == nil { brightnessScreen = screen; originalBrightness = screen?.brightness }
                gestureStart = Double(screen?.brightness ?? 0.5)
            case .volumeUp, .volumeDown: gestureStart = Double(volume.value)
            case .backward, .forward: beginScrubbing(showControls: false, previews: false)
            default: break
            }
        }
        let amount = Double(delta)
        switch gestureAction {
        case .brightnessUp, .brightnessDown:
            let value = min(1, max(0, gestureStart + amount * (gestureAction == .brightnessUp ? 1.5 : -1.5)))
            screen?.brightness = value
            showHUD(String(format: VesperLocalization.string("亮度 %d%%"), Int(value * 100)), symbol: "sun.max.fill")
        case .volumeUp, .volumeDown:
            let value = min(1, max(0, gestureStart + amount * (gestureAction == .volumeUp ? 1.5 : -1.5)))
            session.unmute(); volume.set(Float(value))
            showHUD(String(format: VesperLocalization.string("音量 %d%%"), Int(value * 100)), symbol: "speaker.wave.2.fill")
        case .backward, .forward:
            if isScrubbing {
                // Half a gesture surface seeks five minutes; the destination
                // is clamped by updateScrubbing, not by reducing sensitivity.
                // Double-tap skip duration remains a separate preference.
                let seekSpan: Double = 600
                updateScrubbing(scrubStart + amount * seekSpan * (gestureAction == .backward ? -1 : 1))
                showSeekHUD(from: scrubStart, to: scrubTime)
            }
        default: break
        }
        if [.ended, .cancelled, .failed].contains(phase) {
            if [.volumeUp, .volumeDown].contains(gestureAction) { volume.finishAdjustment(origin: "gesture") }
            if (gestureAction == .backward || gestureAction == .forward) && isScrubbing { finishScrubbing(commit: phase == .ended) }
            else if phase == .ended && ![.brightnessUp, .brightnessDown, .volumeUp, .volumeDown].contains(gestureAction) {
                performGestureAction(gestureAction)
            }
            gestureAction = .none; autoHideRevision += 1
        }
    }

    private var activeRegionLayouts: [Int] {
        let counts = (1...2).flatMap { fingers in
            PlayerGestureKind.allCases.compactMap { kind -> Int? in
                guard !kind.needsTwoFingers || fingers == 2 else { return nil }
                let count = PlayerGesturePreferences.count(for: kind, fingers: fingers)
                let active = PlayerGesturePreferences.regions(for: count).contains {
                    PlayerGesturePreferences.action(kind, $0, fingers) != .none
                }
                return active ? count : nil
            }
        }
        return Array(Set(counts)).sorted()
    }

    private var regionOverlay: some View {
        GeometryReader { geometry in
            let layouts = activeRegionLayouts
            let gaps = CGFloat(max(0, layouts.count - 1)) * 8
            let rowHeight = max(0, (geometry.size.height - gaps) / CGFloat(max(1, layouts.count)))
            VStack(spacing: 8) {
                ForEach(layouts, id: \.self) { count in
                    let edges = [CGFloat(0)] + PlayerGesturePreferences.boundaries(for: count) + [CGFloat(1)]
                    let availableWidth = max(0, geometry.size.width - CGFloat(count - 1) * 2)
                    HStack(spacing: 2) {
                        ForEach(Array(PlayerGesturePreferences.regions(for: count).enumerated()), id: \.element.id) { index, region in
                            let cellWidth = availableWidth * (edges[index + 1] - edges[index])
                            let title: LocalizedStringKey = count == 1 ? "全部区域" : region.title
                            Text(title)
                                .font(.headline)
                                .frame(width: cellWidth, height: rowHeight)
                                .background(.blue.opacity(0.18))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .task(id: regionRevision) {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if !Task.isCancelled { regionsVisible = false }
        }
    }

    private func showHUD(_ text: String, symbol: String, detail: String = "") {
        hudText = text; hudSymbol = symbol; hudDetail = detail; hudRevision += 1
    }
    private func showSeekHUD(from start: Double, to target: Double) {
        let delta = Int((target - start).rounded())
        showHUD(String(format: VesperLocalization.string("%+d 秒"), delta),
                symbol: delta < 0 ? "backward.fill" : "forward.fill",
                detail: "\(timeLabel(target)) / \(timeLabel(session.duration))")
    }
    private func skipSymbol(backward: Bool) -> String {
        "\(backward ? "gobackward" : "goforward").\(Int(PlayerGesturePreferences.skipInterval))"
    }
    private func fraction(_ time: Double) -> CGFloat {
        guard session.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, time / session.duration)))
    }
    private func revealControls() { setControlsVisible(true) }
    private func setControlsVisible(_ visible: Bool) {
        autoHideRevision += 1
        volumeResetRevision += 1
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controlsVisible = visible }
        if !visible { volumeDragStart = nil }
    }
    private func rotate(landscape: Bool) {
        guard let scene = session.videoView?.window?.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscape : .portrait)) { error in
            Task { @MainActor in rotationError = error.localizedDescription; showingNotice = true; revealControls() }
        }
    }
    private func timeLabel(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
private struct PlayerMediaInfoView: View {
    @ObservedObject var session: PlaybackSession
    let showsDetails: Bool
    @State private var details: PlaybackVideoDetails?
    @State private var loading = true
    private func detailGroup(_ field: PlaybackDetailField) -> Int {
        if ["音轨数量", "音频语言", "音频码率", "音频编码", "采样率", "声道数", "音频位深", "声道布局"].contains(field.label) { return 2 }
        if ["容器格式", "总码率", "创建时间", "修改时间"].contains(field.label) { return 0 }
        return 1
    }
    private func detailLabel(_ label: String) -> String {
        switch label {
        case "视频编码", "音频编码": return "编码格式"
        case "视频码率", "音频码率": return "码率"
        case "音频语言": return "语言"
        case "音频位深", "视频位深": return "位深"
        case "视频轨道数量": return "轨道数量"
        case "容器格式": return "封装格式"
        default: return label
        }
    }
    private func detailFields(_ details: PlaybackVideoDetails, group: Int) -> some View {
        ForEach(Array(details.technical.filter { detailGroup($0) == group }.enumerated()), id: \.offset) { _, field in
            LabeledContent { Text(verbatim: field.value).textSelection(.enabled) } label: { Text(LocalizedStringKey(detailLabel(field.label))) }
        }
    }
    var body: some View {
        SettingsPage {
            if loading { ProgressView() }
            if showsDetails {
                if let details {
                    SettingsSection("文件信息") {
                        LabeledContent("文件名") { Text(verbatim: details.fileName).textSelection(.enabled) }
                        LabeledContent("来源") { Text(verbatim: details.sourceName) }
                        if let bytes = details.byteCount {
                            LabeledContent("文件大小") { Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
                        }
                        LabeledContent("时长") { Text(verbatim: mediaTimeLabel(session.duration)) }
                        detailFields(details, group: 0)
                    }
                    SettingsSection("视频信息") {
                        if let dimensions = details.dimensions { LabeledContent("分辨率") { Text(verbatim: dimensions) } }
                        detailFields(details, group: 1)
                    }
                    SettingsSection("音频信息") { detailFields(details, group: 2) }
                } else if !loading { Text("无法读取视频信息").foregroundStyle(.secondary) }
            } else if !loading {
                SettingsSection {
                    if let synopsis = details?.synopsis { Text(verbatim: synopsis).textSelection(.enabled) }
                    else { Text("暂无视频简介").foregroundStyle(.secondary) }
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .navigationTitle(showsDetails ? "详细信息" : "视频简介")
        .toolbarTitleDisplayMode(.inline)
        .task(id: session.currentItem?.id) {
            loading = true
            let result = await session.mediaDetails()
            guard !Task.isCancelled else { return }
            details = result
            loading = false
        }
    }
}

private struct PlayerQueueRow: View {
    @ObservedObject var session: PlaybackSession
    let item: MediaItem
    @State private var info = PlaybackQueueInfo()
    private func time(_ seconds: Double) -> String {
        mediaTimeLabel(seconds)
    }
    var body: some View {
        HStack(spacing: 14) {
            if let source = session.queueSource {
                MediaThumbnail(source: source, item: item, aspectRatio: 16.0 / 9.0, logsQueueDiagnostics: true)
                    .frame(width: 104, height: 58.5)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: (item.title as NSString).deletingPathExtension)
                    .font(.headline).lineLimit(2).foregroundStyle(.primary)
                HStack(spacing: 4) {
                    let progress = session.progress(for: item)
                    Text(verbatim: progress > 0 ? "\(time(progress)) / \(time(info.duration))" : time(info.duration))
                    if let bytes = info.byteCount { Text(verbatim: "· " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
                }
                if let dimensions = info.dimensions { Text(verbatim: dimensions) }
            }
            .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if item.id == session.currentItem?.id { Image(systemName: "waveform").foregroundStyle(.tint) }
        }
        .contentShape(Rectangle())
        .task(id: item.id) {
            PlayerQueueDiagnostic.write("row.begin item=\(item.id.localID)")
            let result = await session.queueInfo(for: item)
            if !Task.isCancelled {
                info = result
                PlayerQueueDiagnostic.write("row.ready item=\(item.id.localID) duration=\(result.duration) bytes=\(result.byteCount ?? 0) dimensions=\(result.dimensions ?? "unknown")")
            }
        }
    }
}

/// Only mounts the existing rendering view. Dismissal detaches its surface,
/// while the app-owned session continues decoding and playing audio.
struct PlayerVideoSurface: UIViewRepresentable {
    let videoView: UIView
    var isActive = true

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ host: UIView, context: Context) {
        guard isActive else {
            if videoView.superview === host { videoView.removeFromSuperview() }
            return
        }
        guard videoView.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        videoView.removeFromSuperview()
        videoView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: host.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    static func dismantleUIView(_ host: UIView, coordinator: ()) {
        host.subviews.forEach { $0.removeFromSuperview() }
    }
}
