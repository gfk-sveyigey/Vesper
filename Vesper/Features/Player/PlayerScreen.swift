import SwiftUI
import UIKit

private enum PlayerPanel: String, Identifiable {
    case queue, gestures, danmaku
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
    @State private var menuPresented = false
    @State private var scrubShowsControls = true
    @State private var scrubTime: Double = 0
    @State private var scrubStart: Double = 0
    @State private var isScrubbing = false
    @State private var resumeAfterScrub = false
    @State private var lastPreview = Date.distantPast
    @State private var panel: PlayerPanel?
    @State private var gestureAction = PlayerGestureAction.none
    @State private var gestureStart: Double = 0
    @State private var originalBrightness: CGFloat?
    @State private var brightnessScreen: UIScreen?
    @State private var hudText = ""
    @State private var hudSymbol = ""
    @State private var hudRevision = 0
    @State private var rotationError: String?
    @State private var showingNotice = false

    private var canAutoHide: Bool {
        controlsVisible && session.isPlaying && !session.isLoading && !session.isSeeking
            && !isScrubbing && !volumeExpanded && !menuPresented && panel == nil && !voiceOver && session.errorMessage == nil
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
                PlayerGestureSurface(tapped: handleTap, panned: handlePan)
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
                    topControls
                    Spacer(minLength: 0)
                    bottomControls(landscape: geometry.size.width > geometry.size.height)
                }
                .padding(.horizontal, geometry.size.width > geometry.size.height ? 28 : 20)
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
                    Label { Text(verbatim: hudText) } icon: { Image(systemName: hudSymbol) }
                        .font(.headline.monospacedDigit()).padding(16)
                        .glassEffect(.regular, in: Capsule())
                        .offset(y: -70)
                        .allowsHitTesting(false)
                }
                if let message = session.errorMessage { errorContent(message) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white).tint(.white)
        }
        .background {
            // Keep MPVolumeView window-attached for public system-volume
            // updates. The visible expanded control binds to this same volume.
            PlayerVolumeBridge(volume: volume)
                .frame(width: 160, height: 40)
                .opacity(0.01).allowsHitTesting(false).accessibilityHidden(true)
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
            if isScrubbing { finishScrubbing() }
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
        .onChange(of: voiceOver) { _, _ in revealControls() }
        .onChange(of: panel) { _, _ in revealControls() }
        .onChange(of: scenePhase) { _, phase in if phase != .active && isScrubbing { finishScrubbing() } }
        .task(id: autoHideRevision) {
            guard canAutoHide else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled, canAutoHide else { return }
            setControlsVisible(false)
        }
        .task(id: hudRevision) {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled else { return }
            hudText = ""
        }
    }

    private var topControls: some View {
        HStack(alignment: .top, spacing: 10) {
            glassButton("关闭", symbol: "xmark") { session.stop() }
            HStack(spacing: 0) {
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
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 10) {
                glassButton("音量", symbol: session.isMuted || volume.value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                    volumeExpanded.toggle()
                }
                if volumeExpanded {
                    HStack(spacing: 8) {
                        Button { session.toggleMute() } label: {
                            Image(systemName: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain).accessibilityLabel(session.isMuted ? "取消静音" : "静音")
                        Slider(value: Binding(get: { volume.value }, set: { session.unmute(); volume.set($0) }), in: 0...1)
                            .frame(width: 120).accessibilityLabel("音量")
                            .padding(.trailing, 16)
                    }
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
        }
    }

    private var transportControls: some View {
        HStack(spacing: 36) {
            glassButton("快退", symbol: skipSymbol(backward: true), size: 54) {
                session.seek(to: session.currentTime - PlayerGesturePreferences.skipInterval)
            }.disabled(!session.canSeek)
            glassButton(session.isPlaying ? "暂停" : "播放",
                        symbol: session.isPlaying ? "pause.fill" : "play.fill", size: 76) {
                session.togglePlayback()
            }.disabled(!session.canControl)
            glassButton("快进", symbol: skipSymbol(backward: false), size: 54) {
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
                moreMenu(landscape: landscape)
            }
            HStack(spacing: 10) {
                Text(timeLabel(isScrubbing ? scrubTime : session.currentTime))
                    .frame(minWidth: 40, alignment: .leading)
                progressBar
                Text(timeLabel(session.duration)).frame(minWidth: 40, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
        }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: isScrubbing ? 12 : 8)
                Capsule().fill(.white.opacity(0.35)).frame(width: geometry.size.width * fraction(session.bufferedTime), height: isScrubbing ? 12 : 8)
                Capsule().fill(.white).frame(width: geometry.size.width * fraction(isScrubbing ? scrubTime : session.currentTime), height: isScrubbing ? 12 : 8)
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard session.canSeek else { return }
                    if !isScrubbing { beginScrubbing() }
                    updateScrubbing(Double(value.location.x / max(geometry.size.width, 1)) * session.duration)
                }
                .onEnded { value in
                    guard isScrubbing else { return }
                    updateScrubbing(Double(value.location.x / max(geometry.size.width, 1)) * session.duration)
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

    private func moreMenu(landscape: Bool) -> some View {
        PlayerMenuButton(makeMenu: { makeMoreMenu(landscape: landscape) }) { presented in
            menuPresented = presented
            revealControls()
        }
        .frame(width: 44, height: 44)
        .glassEffect(.regular.interactive(), in: Circle())
    }

    private func makeMoreMenu(landscape: Bool) -> UIMenu {
        let speeds = [Float(0.5), 0.75, 1, 1.25, 1.5, 2].map { rate in
            menuAction(String(format: "%g×", Double(rate)), selected: session.playbackRate == rate) {
                session.setPlaybackRate(rate)
            }
        }
        var subtitles = [menuAction(VesperLocalization.string("关闭字幕"), selected: session.selectedSubtitleID == nil) {
            session.selectSubtitle(nil)
        }]
        subtitles += session.subtitleTracks.map { track in
            menuAction(track.name, selected: track.isSelected) { session.selectSubtitle(track.id) }
        }
        if session.subtitleTracks.isEmpty {
            subtitles.append(menuAction(VesperLocalization.string("无内嵌字幕"), enabled: false) { })
        }
        var audio = session.audioTracks.map { track in
            menuAction(track.name, selected: track.isSelected) { session.selectAudio(track.id) }
        }
        if audio.isEmpty { audio.append(menuAction(VesperLocalization.string("无可用音轨"), enabled: false) { }) }
        let settings: [UIMenuElement] = [
            UIMenu(title: VesperLocalization.string("播放速度"), children: speeds),
            UIMenu(title: VesperLocalization.string("字幕"), children: subtitles),
            UIMenu(title: VesperLocalization.string("音轨"), children: audio),
            menuAction(VesperLocalization.string("弹幕设置"), symbol: "text.bubble") { panel = .danmaku },
            menuAction(VesperLocalization.string("播放列表"), symbol: "list.bullet", enabled: !session.queue.isEmpty) { panel = .queue },
            menuAction(VesperLocalization.string("播放器手势"), symbol: "hand.draw") { panel = .gestures }
        ]
        let picture: [UIMenuElement] = [
            menuAction(VesperLocalization.string(session.fillsScreen ? "完整显示" : "填满屏幕"), symbol: "aspectratio") { session.toggleFill() },
            menuAction(VesperLocalization.string(landscape ? "竖屏" : "横屏"), symbol: "rotate.right") { rotate(landscape: !landscape) }
        ]
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: settings),
            UIMenu(options: .displayInline, children: picture)
        ])
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
                    .font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.center)
                    .foregroundStyle(.white).shadow(color: .black, radius: 2, x: 1, y: 1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 20).padding(.bottom, controlsVisible ? 126 : 24)
        .frame(maxWidth: .infinity)
    }

    private func glassButton(_ title: LocalizedStringKey, symbol: String, size: CGFloat = 44,
                             action: @escaping () -> Void) -> some View {
        Button { revealControls(); action() } label: {
            Image(systemName: symbol)
                .font(.system(size: size == 76 ? 32 : (size == 54 ? 23 : 17), weight: .medium))
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
                case .gestures: PlayerGestureSettingsView()
                case .danmaku:
                    ContentUnavailableView("弹幕设置", systemImage: "text.bubble", description: Text("尚未接入弹幕来源。"))
                        .navigationTitle("弹幕设置")
                case .queue:
                    List(session.queue) { item in
                        Button {
                            session.playQueued(item)
                            panel = nil
                        } label: {
                            HStack {
                                Text(verbatim: item.title).lineLimit(2)
                                Spacer()
                                if item.id == session.currentItem?.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    .navigationTitle("播放列表")
                }
            }
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { panel = nil } }
            }
        }
    }

    private func beginScrubbing(showControls: Bool = true) {
        guard session.canSeek else { return }
        scrubShowsControls = showControls
        resumeAfterScrub = session.isPlaying
        scrubStart = session.currentTime
        scrubTime = scrubStart
        isScrubbing = true
        lastPreview = .distantPast
        session.pause()
        if showControls { revealControls() }
    }
    private func updateScrubbing(_ target: Double) {
        scrubTime = min(session.duration, max(0, target))
        if Date().timeIntervalSince(lastPreview) >= 0.15 {
            lastPreview = Date()
            session.seek(to: scrubTime, resume: false)
        }
    }
    private func finishScrubbing() {
        let target = scrubTime
        isScrubbing = false
        session.seek(to: target, resume: resumeAfterScrub)
        if scrubShowsControls { revealControls() }
        else { autoHideRevision += 1 }
    }

    private func handleTap(_ region: PlayerGestureRegion, _ fingers: Int, _ double: Bool) {
        guard !menuPresented, panel == nil else { return }
        if controlsVisible {
            // The visible overlay only accepts its buttons and a one-finger
            // background tap to hide. Playback/brightness/volume gestures are
            // reserved for the unobstructed video.
            if !double && fingers == 1 { setControlsVisible(false) }
            return
        }
        let action = PlayerGesturePreferences.action(double ? .doubleTap : .tap, region, fingers)
        switch action {
        case .controls: setControlsVisible(!controlsVisible)
        case .playback: session.togglePlayback()
        case .backward, .forward:
            let delta = PlayerGesturePreferences.skipInterval * (action == .backward ? -1 : 1)
            session.seek(to: session.currentTime + delta)
            showHUD(timeLabel(session.currentTime), symbol: skipSymbol(backward: delta < 0))
        default: break
        }
    }

    private func handlePan(_ region: PlayerGestureRegion, _ fingers: Int, _ kind: PlayerGestureKind,
                           _ delta: CGFloat, _ phase: UIGestureRecognizer.State) {
        if phase == .began {
            guard !controlsVisible, !menuPresented, panel == nil else {
                gestureAction = .none
                return
            }
            gestureAction = PlayerGesturePreferences.action(kind, region, fingers)
            switch gestureAction {
            case .brightness:
                if originalBrightness == nil { brightnessScreen = screen; originalBrightness = screen?.brightness }
                gestureStart = Double(screen?.brightness ?? 0.5)
            case .volume: gestureStart = Double(volume.value)
            case .seek: beginScrubbing(showControls: false)
            default: break
            }
        }
        switch gestureAction {
        case .brightness:
            let value = min(1, max(0, gestureStart + Double(delta) * 1.5))
            screen?.brightness = CGFloat(value)
            showHUD(String(format: VesperLocalization.string("亮度 %d%%"), Int(value * 100)), symbol: "sun.max.fill")
        case .volume:
            let value = min(1, max(0, gestureStart + Double(delta) * 1.5))
            session.unmute()
            volume.set(Float(value))
            showHUD(String(format: VesperLocalization.string("音量 %d%%"), Int(value * 100)), symbol: "speaker.wave.2.fill")
        case .seek:
            if isScrubbing {
                updateScrubbing(scrubStart + Double(delta) * min(session.duration, 120))
                showHUD(timeLabel(scrubTime), symbol: "play.rectangle")
            }
        default: break
        }
        if phase == .ended || phase == .cancelled || phase == .failed {
            if gestureAction == .seek && isScrubbing { finishScrubbing() }
            gestureAction = .none
            autoHideRevision += 1
        }
    }

    private func showHUD(_ text: String, symbol: String) {
        hudText = text; hudSymbol = symbol; hudRevision += 1
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
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { controlsVisible = visible }
        if !visible { volumeExpanded = false }
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
