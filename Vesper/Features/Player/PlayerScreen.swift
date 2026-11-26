import SwiftUI
import UIKit
import UniformTypeIdentifiers
import AVFoundation
import QuartzCore
import PlaybackContracts

/// An Observation tracking boundary: timeline changes invalidate this region only.
private struct PlayerTimelineRegion<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View { content() }
}

private enum PlayerPanel: String, Identifiable {
    case queue, gestures, danmaku, danmakuSearch, subtitles, synopsis, details, more
    var id: String { rawValue }
}

private struct PlayerVolumeGlyph: View {
    let level: Double
    let isMuted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var slash: Path {
        Path { path in
            path.move(to: CGPoint(x: 3, y: 2))
            path.addLine(to: CGPoint(x: 24, y: 20))
        }
    }

    var body: some View {
        let slashProgress: CGFloat = isMuted ? 1 : 0
        ZStack {
            ZStack(alignment: .leading) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 14, height: 22)
                    .offset(x: isMuted ? 5 : 0)

                ForEach(0..<3) { index in
                    let step = CGFloat(index)
                    let isLit = level > Double(index) / 3
                    let fadeOrder = isMuted ? 2 - index : index
                    Path { path in
                        let x = 15 + step * 4
                        let halfHeight = 3 + step * 2.5
                        path.move(to: CGPoint(x: x, y: 11 - halfHeight))
                        path.addQuadCurve(to: CGPoint(x: x, y: 11 + halfHeight),
                                          control: CGPoint(x: x + 3, y: 11))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .opacity(isLit ? 1 : 0.25)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isLit)
                    .opacity(isMuted ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18).delay(Double(fadeOrder) * 0.035),
                               value: isMuted)
                }

                slash.trim(from: 0, to: slashProgress)
                    .stroke(style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .blendMode(.destinationOut)
            }
            .compositingGroup()

            slash.trim(from: 0, to: slashProgress)
                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .frame(width: 27, height: 22)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isMuted)
    }
}

struct PlayerScreen: View {
    @ObservedObject var session: PlaybackSession
    @StateObject private var volume = PlayerSystemVolume()
    @StateObject private var airPlayAvailability = PlayerAirPlayAvailability()
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var controlsVisible = false
    @State private var autoHideRevision = 0
    @State private var volumeExpanded = false
    @State private var volumeResetRevision = 0
    @State private var showsSystemVolume = false
    @State private var systemVolumeRevision = 0
    @State private var volumeDragStart: Float?
    @State private var menuPresented = false
    @State private var scrubShowsControls = true
    @State private var scrubPreviews = true
    @State private var scrubTime: Double = 0
    @State private var scrubStart: Double = 0
    @State private var isScrubbing = false
    @State private var resumeAfterScrub = false
    @State private var lastPreview = Date.distantPast
    @State private var panel: PlayerPanel?
    @State private var pendingPanel: PlayerPanel?
    @State private var pendingRotation: Bool?
    @State private var pendingDanmakuImport = false
    @State private var importingDanmaku = false
    @State private var importDocument: PlayerDanmaku?
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
    @State private var hudDuration: Double = 1
    @State private var rotationError: String?
    @State private var showingNotice = false
    @State private var debugInfoVisible = false

    private var canAutoHide: Bool {
        controlsVisible && session.isPlaying && !session.isLoading && !session.isSeeking
            && !isScrubbing && !importingDanmaku && !volumeExpanded && !showsSystemVolume && volumeDragStart == nil && !menuPresented && panel == nil && !voiceOver && session.errorMessage == nil
    }
    private var screen: UIScreen? { session.videoView?.window?.windowScene?.screen }
    private var showsOtherControls: Bool { controlsVisible && !isScrubbing }
    private var usesCompactProgress: Bool { isScrubbing && !scrubShowsControls }
    private var canShowSystemVolume: Bool {
        scenePhase != .background && session.isPresented && panel == nil && !importingDanmaku
    }
    private var needsSystemVolumePolling: Bool {
        // Supplement volume notifications while the visible player may lack audio focus.
        canShowSystemVolume && (!session.isPlaying || scenePhase == .inactive)
    }

    var body: some View {
        observedPlayer
            .task { await session.monitorDownloadSpeed() }
            .task(id: needsSystemVolumePolling) {
                guard needsSystemVolumePolling else { return }
                while !Task.isCancelled {
                    volume.refreshSystemVolume()
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                }
            }
            .task(id: hudRevision) { await dismissHUDWhenReady() }
            .task(id: autoHideRevision) { await autoHideControlsWhenReady() }
            .task(id: volumeResetRevision) { await resetVolumeWhenReady() }
            .task(id: systemVolumeRevision) { await hideSystemVolumeWhenReady() }
            .fileImporter(isPresented: $importingDanmaku, allowedContentTypes: [.xml], onCompletion: handleDanmakuImport)
    }

    private var observedPlayer: some View {
        presentedPlayer
        .onAppear {
            PlayerOrientationPolicy.update(true, scene: session.videoView?.window?.windowScene)
            session.playerDidAppear()
            airPlayAvailability.start()
            brightnessScreen = screen
            originalBrightness = screen?.brightness
            scrubTime = session.currentTime
            setControlsVisible(voiceOver || session.errorMessage != nil)
        }
        .onDisappear {
            airPlayAvailability.stop()
            if isScrubbing { finishScrubbing(commit: scrubPreviews) }
            if let originalBrightness { brightnessScreen?.brightness = originalBrightness }
        }
        .onChange(of: session.currentItem?.id) { _, _ in
            isScrubbing = false
            scrubTime = 0
            showsSystemVolume = false
            setControlsVisible(voiceOver)
        }
        .onChange(of: session.isPlaying) { _, _ in autoHideRevision += 1 }
        .onChange(of: session.isLoading) { _, _ in autoHideRevision += 1 }
        .onChange(of: session.isSeeking) { _, _ in autoHideRevision += 1 }
        .onChange(of: session.errorMessage) { _, message in if message != nil { revealControls() } }
        .onChange(of: session.playbackNotice) { _, message in if message != nil { showingNotice = true; revealControls() } }
        .onChange(of: session.playbackTransitionNotice) { _, notice in
            guard let notice else { return }
            showHUD(notice.message, symbol: "arrow.triangle.2.circlepath", duration: 3)
        }
        .onChange(of: session.automaticSkipNotice) { _, notice in
            guard let notice else { return }
            showHUD(VesperLocalization.string(notice.kind == .intro ? "已跳过片头" : "已跳过片尾"),
                    symbol: notice.kind == .intro ? "forward.fill" : "forward.end.fill")
        }
        .onChange(of: volume.value) { old, new in if new > 0.001 && old != new && session.isMuted { session.unmute() } }
        .onReceive(volume.externalChanges) { _ in
            guard canShowSystemVolume else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsSystemVolume = true }
            systemVolumeRevision += 1
            autoHideRevision += 1
        }
        .onChange(of: volumeDragStart) { _, _ in
            autoHideRevision += 1
            if showsSystemVolume { systemVolumeRevision += 1 }
        }
        .onChange(of: voiceOver) { _, _ in revealControls() }
        .onChange(of: panel) { _, _ in revealControls() }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            if phase == .background { showsSystemVolume = false }
            if isScrubbing { finishScrubbing(commit: scrubPreviews) }
        }
    }

    @MainActor private func autoHideControlsWhenReady() async {
        guard canAutoHide else { return }
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
        guard !Task.isCancelled, canAutoHide else { return }
        setControlsVisible(false)
    }

    @MainActor private func resetVolumeWhenReady() async {
        guard !controlsVisible else { return }
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard !Task.isCancelled, !controlsVisible else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { volumeExpanded = false; volumeDragStart = nil }
    }

    @MainActor private func hideSystemVolumeWhenReady() async {
        guard showsSystemVolume, volumeDragStart == nil else { return }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        guard !Task.isCancelled, showsSystemVolume, volumeDragStart == nil else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsSystemVolume = false }
        autoHideRevision += 1
    }

    private var presentedPlayer: some View {
        // Read safe-area margins outside the edge-to-edge viewport. Video,
        // transport and UIKit rotation now share the full-screen midpoint;
        // only the peripheral controls are inset into the safe area.
        GeometryReader { safeGeometry in
            GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                if let view = session.videoView {
                    PlayerVideoSurface(videoView: view, videoSize: session.videoSize,
                                       fillsScreen: session.fillsScreen, isActive: session.isPresented)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                DanmakuOverlay(session: session, document: session.danmaku)
                    .id(ObjectIdentifier(session.danmaku))
                if debugInfoVisible && !isScrubbing {
                    diagnosticOverlay
                        .padding(12)
                        .padding(safeGeometry.safeAreaInsets)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .contain)
                        .zIndex(10)
                }
                PlayerGestureSurface(tapped: handleTap, held: { region, fingers in
                    guard !regionsVisible, !controlsVisible, !menuPresented, panel == nil else { return }
                    performGestureAction(PlayerGesturePreferences.action(.longPress, region, fingers))
                }, panned: handlePan)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.75)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .opacity(showsOtherControls ? 1 : 0)
                    .allowsHitTesting(false)
                // Independent placement keeps the transport centered on the
                // actual video, regardless of header/title/progress height.
                transportControls
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    .opacity(showsOtherControls && session.errorMessage == nil && !session.isLoading ? 1 : 0)
                    .allowsHitTesting(showsOtherControls && session.errorMessage == nil && !session.isLoading)
                    .accessibilityHidden(!showsOtherControls || session.errorMessage != nil || session.isLoading)
                VStack {
                    topControls(availableWidth: max(0, geometry.size.width - safeGeometry.safeAreaInsets.leading - safeGeometry.safeAreaInsets.trailing - (geometry.size.width > geometry.size.height ? 24 : 40)), landscape: geometry.size.width > geometry.size.height)
                    Spacer(minLength: 0)
                    // Keep the Menu mounted while fading the controls, so a
                    // system menu never loses its presentation anchor mid-use.
                    bottomControls(landscape: geometry.size.width > geometry.size.height)
                        .opacity(controlsVisible && !usesCompactProgress ? 1 : 0)
                        .allowsHitTesting(controlsVisible)
                        .accessibilityHidden(!controlsVisible)
                }
                .padding(.horizontal, geometry.size.width > geometry.size.height ? 12 : 20)
                .padding(.vertical, 12)
                .padding(safeGeometry.safeAreaInsets)
                if (session.isLoading || session.isSeeking) && !isScrubbing {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large).tint(.white)
                            .accessibilityLabel("正在加载")
                        PlayerTimelineRegion { Text(verbatim: session.downloadSpeedText) }
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    .allowsHitTesting(false)
                }
                if !hudText.isEmpty && !(isScrubbing && scrubShowsControls) {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: hudSymbol)
                            Text(verbatim: hudText).fontWeight(.semibold).lineLimit(2)
                            if !hudDetail.isEmpty {
                                Text(verbatim: hudDetail).foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.top, safeGeometry.safeAreaInsets.top + (controlsVisible ? 62 : 8))
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
                if regionsVisible && !isScrubbing { regionOverlay.ignoresSafeArea() }
                if let message = session.errorMessage, !isScrubbing { errorContent(message) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if usesCompactProgress {
                    progressCapsule(height: 30)
                        .frame(height: 30)
                        .padding(.leading, safeGeometry.safeAreaInsets.leading)
                        .padding(.trailing, safeGeometry.safeAreaInsets.trailing)
                        .padding(.horizontal, geometry.size.width > geometry.size.height ? 12 : 20)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(.white).tint(.white)
            }
            .ignoresSafeArea(.container)
        }
        .overlay(alignment: .topLeading) {
            PlayerVolumeBridge(volume: volume)
                .frame(width: 160, height: 44)
                .accessibilityHidden(true)
        }
        .background {
            PlayerInterfaceRefreshDriver(
                isActive: scenePhase == .active && session.isPresented && panel == nil
                    && (controlsVisible || showsSystemVolume || menuPresented || showingNotice || regionsVisible || !hudText.isEmpty)
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
                .background {
                    // A full-height sheet may detach the presenting view.
                    // Keep its UI cadence request inside the visible sheet.
                    PlayerInterfaceRefreshDriver(
                        isActive: scenePhase == .active
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .environment(\.settingsIntroCardsHidden, true)
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
    }

    @MainActor private func dismissHUDWhenReady() async {
        let delay: Duration = .seconds(hudDuration)
        do { try await Task.sleep(for: delay) } catch { return }
        guard !Task.isCancelled else { return }
        hudText = ""
    }

    private func topControls(availableWidth: CGFloat, landscape: Bool) -> some View {
        let showsButtons = showsOtherControls && (landscape || !(volumeExpanded || showsSystemVolume))
        let showsVolume = showsOtherControls || showsSystemVolume
        return ZStack(alignment: .trailing) {
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
                    PlayerAirPlayButton(isAvailable: airPlayAvailability.isAvailable)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("投屏")
                }
                .glassEffect(.regular.interactive(), in: Capsule())
                Spacer(minLength: 0)
            }
            .opacity(showsButtons ? 1 : 0)
            .allowsHitTesting(showsButtons)
            .accessibilityHidden(!showsButtons)
            volumeControl(width: min(240, availableWidth), landscape: landscape)
                .opacity(showsVolume ? 1 : 0)
                .allowsHitTesting(showsVolume)
                .accessibilityHidden(!showsVolume)
        }
        .frame(height: 44)
    }

    private var audioIsMuted: Bool { session.isMuted || volume.value <= 0.001 }
    private var displayedVolume: Double { audioIsMuted ? 0 : Double(volume.value) }
    private func toggleAudioMute() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            if audioIsMuted {
                session.unmute()
                if volume.value <= 0.001 { volume.set(0.1) }
            } else { session.toggleMute() }
        }
    }

    private func volumeControl(width: CGFloat, landscape: Bool) -> some View {
        let expanded = landscape || volumeExpanded || showsSystemVolume
        return Color.clear
            .frame(width: expanded ? max(44, width) : 44, height: 44)
            .overlay(alignment: .trailing) {
                Capsule().fill(.white.opacity(0.2))
                    .overlay {
                        Rectangle().fill(.white)
                            .scaleEffect(x: CGFloat(displayedVolume), y: 1, anchor: .leading)
                            .animation(reduceMotion || volumeDragStart != nil ? nil : .easeOut(duration: 0.18),
                                       value: displayedVolume)
                    }
                    .clipShape(Capsule())
                    .frame(width: max(0, width - 72), height: 8)
                    .padding(.trailing, 56)
                    .opacity(expanded ? 1 : 0)
            }
            .clipShape(Capsule())
            .allowsHitTesting(false)
            .glassEffect(.regular.interactive(), in: Capsule())
            .overlay(alignment: .trailing) {
                PlayerVolumeGlyph(level: Double(volume.value), isMuted: audioIsMuted)
                    .frame(width: 44, height: 44)
                    .allowsHitTesting(false)
            }
            .overlay {
                PlayerVolumeTouchSurface(expanded: expanded, tapped: { onIcon in
                    if showsSystemVolume {
                        if onIcon { toggleAudioMute() }
                        systemVolumeRevision += 1
                        return
                    }
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: expanded)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音量")
        .accessibilityValue(Text(verbatim: String(format: "%d%%", Int(displayedVolume * 100))))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if showsSystemVolume {
                toggleAudioMute()
                systemVolumeRevision += 1
                return
            }
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
                    if let subtitle = session.playbackSubtitle, !subtitle.isEmpty {
                        Text(verbatim: subtitle).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    }
                    Text(verbatim: session.currentItem?.title ?? VesperLocalization.string("未在播放"))
                        .font(landscape ? .headline : .title3.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if landscape { expandedPlaybackOptions }
                else { playbackOptionsMenu }
            }
            .opacity(showsOtherControls ? 1 : 0)
            .allowsHitTesting(showsOtherControls)
            .accessibilityHidden(!showsOtherControls)
            progressCapsule(height: 56.0 * 2 / 3)
                .scaleEffect(isScrubbing && scrubShowsControls ? 1.06 : 1)
            bottomActions(landscape: landscape)
                .opacity(showsOtherControls ? 1 : 0)
                .allowsHitTesting(showsOtherControls)
                .accessibilityHidden(!showsOtherControls)
        }
        .animation(.easeInOut(duration: 0.18), value: isScrubbing)
    }

    private func progressCapsule(height: CGFloat) -> some View {
        progressRow
            .padding(.horizontal, 12)
            .background {
                Color.clear
                    .frame(height: height)
                    .glassEffect(.regular, in: Capsule())
                    .allowsHitTesting(false)
            }
    }

    private var progressRow: some View {
        PlayerTimelineRegion { progressRowContent }
    }

    private var progressRowContent: some View {
        HStack(spacing: 10) {
            Text(timeLabel(isScrubbing ? scrubTime : session.currentTime))
                .frame(minWidth: 40, alignment: .leading)
            progressBar
            Text(timeLabel(PlaybackPreferences.showsRemainingDuration
                           ? max(0, session.duration - (isScrubbing ? scrubTime : session.currentTime))
                           : session.duration))
                .frame(minWidth: 40, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .animation(.easeInOut(duration: 0.18), value: isScrubbing)
    }

    private var progressBar: some View {
        let trackHeight: CGFloat = usesCompactProgress ? 6 : 8
        let segments = progressBufferRanges.compactMap { range -> ClosedRange<CGFloat>? in
            guard range.lowerBound.isFinite, range.upperBound.isFinite else { return nil }
            let start = fraction(range.lowerBound)
            let end = fraction(range.upperBound)
            return start < end ? start...end : nil
        }
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: trackHeight)
                Capsule().fill(.white.opacity(0.35))
                    .frame(height: trackHeight)
                    .mask { PlayerBufferMask(segments: segments) }
                Capsule().fill(.white)
                    .frame(height: trackHeight)
                    .frame(maxWidth: .infinity)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geometry.size.width * fraction(isScrubbing ? scrubTime : session.currentTime))
                    }
            }
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
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
                         makeMenu: { UIMenu(children: [speedMenu(), audioMenu(), subtitleMenu(), danmakuMenu(), introOutroMenu()]) },
                         visibilityChanged: menuVisibilityChanged)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
    }

    private func danmakuMenu() -> UIMenu {
        UIMenu(title: VesperLocalization.string("弹幕"), image: UIImage(systemName: "text.bubble"),
               children: danmakuSourceActions())
    }

    private func introOutroMenu() -> UIMenu {
        UIMenu(title: VesperLocalization.string("片头片尾"), image: UIImage(systemName: "forward.end"), children: [
            menuAction(VesperLocalization.string("自动跳过片头"), selected: EmbySkipSettings.introEnabled) {
                UserDefaults.standard.set(!EmbySkipSettings.introEnabled, forKey: EmbySkipSettings.introKey)
            },
            menuAction(VesperLocalization.string("自动跳过片尾"), selected: EmbySkipSettings.outroEnabled) {
                UserDefaults.standard.set(!EmbySkipSettings.outroEnabled, forKey: EmbySkipSettings.outroKey)
            }
        ])
    }

    private func danmakuSourceActions() -> [UIMenuElement] {
        [
            menuAction(VesperLocalization.string("搜索弹幕"), symbol: "text.magnifyingglass") {
                requestPanel(.danmakuSearch)
            },
            menuAction(VesperLocalization.string("导入本地弹幕文件"), symbol: "doc.badge.plus",
                       enabled: !session.danmaku.isImporting) {
                pendingDanmakuImport = true
                if !menuPresented { performMenuNavigation() }
            }
        ]
    }

    private func handleDanmakuImport(_ result: Result<URL, Error>) {
        guard let document = importDocument else { return }
        importDocument = nil
        Task { @MainActor in
            do {
                try await document.importFile(result.get())
                guard session.danmaku === document else { return }
                showHUD(VesperLocalization.string("弹幕已导入"), symbol: "text.bubble")
            } catch {
                if (error as NSError).code != CocoaError.userCancelled.rawValue {
                    session.playbackNotice = VesperLocalization.string("弹幕导入失败：") + error.localizedDescription
                }
            }
        }
    }

    private func speedMenu() -> UIMenu {
        UIMenu(title: VesperLocalization.string("播放速度"), image: UIImage(systemName: "speedometer"), children:
            [Float(0.5), 0.75, 1, 1.25, 1.5, 2].map { rate in
                menuAction(String(format: "%g×", Double(rate)), selected: session.playbackRate == rate) { session.setPlaybackRate(rate) }
            }
        )
    }

    private func subtitleMenu() -> UIMenu {
        let restoring = session.subtitleRestoreStatus
        var actions = [menuAction(VesperLocalization.string("关闭字幕"),
                                  selected: session.subtitlesExplicitlyOff || (session.selectedSubtitleID == nil && restoring == .none)) {
            session.selectSubtitle(nil)
        }]
        actions += session.subtitleTracks.map { track in
            menuAction(track.name, selected: track.isSelected) { session.selectSubtitle(track.id) }
        }
        switch restoring {
        case .restoring: actions.append(menuAction(VesperLocalization.string("正在恢复字幕"), enabled: false) { })
        case .unavailable: actions.append(menuAction(VesperLocalization.string("未能恢复原字幕轨"), enabled: false) { })
        case .none:
            if session.subtitleTracks.isEmpty { actions.append(menuAction(VesperLocalization.string("无内嵌字幕"), enabled: false) { }) }
        }
        actions.append(menuAction(VesperLocalization.string("字幕样式"), symbol: "textformat.size") {
            requestPanel(.subtitles)
        })
        return UIMenu(title: VesperLocalization.string("字幕"), image: UIImage(systemName: "captions.bubble"), children: actions)
    }

    private func audioMenu() -> UIMenu {
        var actions = session.audioTracks.map { track in
            menuAction(track.name, selected: track.isSelected) { session.selectAudio(track.id) }
        }
        switch session.audioRestoreStatus {
        case .restoring: actions.append(menuAction(VesperLocalization.string("正在恢复音轨"), enabled: false) { })
        case .unavailable: actions.append(menuAction(VesperLocalization.string("未能恢复原音轨"), enabled: false) { })
        case .none:
            if actions.isEmpty { actions.append(menuAction(VesperLocalization.string("无可用音轨"), enabled: false) { }) }
        }
        return UIMenu(title: VesperLocalization.string("音频"), image: UIImage(systemName: "waveform"), children: actions)
    }

    private var expandedPlaybackOptions: some View {
        HStack(spacing: 16) {
            landscapeMenu("播放速度", symbol: "speedometer", menu: speedMenu)
            landscapeMenu("音频", symbol: "waveform", menu: audioMenu)
            landscapeMenu("字幕", symbol: "captions.bubble", menu: subtitleMenu)
            landscapeMenu("播放选项", symbol: "ellipsis", menu: { UIMenu(children: [danmakuMenu(), introOutroMenu()]) })
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("播放选项")
        .fixedSize(horizontal: true, vertical: false)
    }

    private var diagnosticOverlay: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 5) {
                Text("\(VesperLocalization.string("播放调试信息")) · \(session.diagnosticEngineTitle)")
                    .font(.caption.weight(.semibold))
                let metrics = session.diagnosticMetrics
                if metrics.isEmpty {
                    Text(VesperLocalization.string("暂无调试数据"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(metrics) { metric in
                        HStack(spacing: 12) {
                            Text(verbatim: VesperLocalization.string(metric.title))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(verbatim: metric.value)
                                .monospacedDigit()
                        }
                        .font(.caption2)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: 320, alignment: .leading)
            .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
        }
    }

    private func bottomActions(landscape: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 12) {
                compactAction("视频简介", symbol: "text.book.closed") { requestPanel(.synopsis) }
                compactAction("详细信息", symbol: "info.circle") { requestPanel(.details) }
                    .disabled(!session.canShowMediaDetails)
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            PlayerActionButton(title: VesperLocalization.string("显示调试信息"), symbol: "ladybug", pointSize: 14) {
                revealControls()
                debugInfoVisible.toggle()
            }
            .frame(width: 36, height: 36)
            .glassEffect(.regular.interactive(), in: Circle())
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
        if selected == .details && !session.canShowMediaDetails { return }
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
            if pendingDanmakuImport {
                pendingDanmakuImport = false
                importDocument = session.danmaku
                importingDanmaku = true
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
                            NavigationLink("弹幕设置") { PlayerDanmakuSettingsView(document: session.danmaku) }
                            NavigationLink("字幕设置") { PlayerSubtitleSettingsView(session: session) }
                            NavigationLink("播放手势") { PlayerGestureSettingsView() }
                        }
                    }.contentMargins(.top, 0, for: .scrollContent).navigationTitle("更多设置")
                case .gestures: PlayerGestureSettingsView()
                case .danmaku: PlayerDanmakuSettingsView(document: session.danmaku)
                case .danmakuSearch:
                    DanmakuAPISearchView(document: session.danmaku, item: session.currentItem,
                                         mediaSource: session.queueSource)
                        .id(ObjectIdentifier(session.danmaku))
                case .subtitles: PlayerSubtitleSettingsView(session: session)
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
        if scrubPreviews { session.pause() }
        if showControls { revealControls() }
    }
    private func updateScrubbing(_ target: Double) {
        scrubTime = min(session.duration, max(0, target))
        let interval = session.currentEngine == .vlc ? 0.35 : 0.15
        if scrubPreviews && Date().timeIntervalSince(lastPreview) >= interval {
            lastPreview = Date()
            session.seek(to: scrubTime, resume: false, preview: true)
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
        case .debugInfo: return "显隐调试信息"
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
        if action != .none && action != .controls && ![.backward, .forward, .brightnessUp, .brightnessDown, .volumeUp, .volumeDown, .speedUp, .speedDown].contains(action) {
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
        case .debugInfo: debugInfoVisible.toggle()
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
            let format = VesperLocalization.string(action == .speedUp ? "加快至 %g×" : "减慢至 %g×")
            showHUD(String(format: format, Double(session.playbackRate)), symbol: "speedometer")
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

    private func showHUD(_ text: String, symbol: String, detail: String = "", duration: Double = 1) {
        hudText = text; hudSymbol = symbol; hudDetail = detail; hudDuration = duration; hudRevision += 1
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
    private var progressBufferRanges: [ClosedRange<Double>] {
        if !session.bufferedRanges.isEmpty { return session.bufferedRanges }
        guard session.bufferedTime > session.currentTime else { return [] }
        return [session.currentTime...session.bufferedTime]
    }

    private func fraction(_ time: Double) -> CGFloat {
        guard time.isFinite, session.duration.isFinite, session.duration > 0 else { return 0 }
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
                        if !details.fileName.isEmpty {
                            LabeledContent("文件名") { Text(verbatim: details.fileName).textSelection(.enabled) }
                        }
                        LabeledContent("来源") { Text(verbatim: details.sourceName) }
                        if let bytes = details.byteCount {
                            LabeledContent("文件大小") { Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
                        }
                        if let duration = details.duration {
                            LabeledContent("时长") { Text(verbatim: mediaTimeLabel(duration)) }
                        }
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
        .task(id: "\(session.currentItem?.id.localID ?? "")|\(session.currentEngine.rawValue)|\(session.currentDecoder.rawValue)") {
            loading = true
            details = nil
            let result = await session.mediaDetails(showsDetails: showsDetails)
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
                MediaThumbnail(source: source, item: item, aspectRatio: 16.0 / 9.0,
                               imageOrientation: .landscape, logsQueueDiagnostics: true,
                               usesMediaCardBackdrop: false)
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

/// UIKit owns the orientation transition; do not apply a separate SwiftUI
/// rotation or recreate the engine's rendering surface during it.
struct PlayerVideoSurface: UIViewControllerRepresentable {
    let videoView: UIView
    let videoSize: CGSize?
    let fillsScreen: Bool
    var isActive = true

    func makeUIViewController(context: Context) -> PlayerVideoSurfaceController {
        PlayerVideoSurfaceController()
    }
    func updateUIViewController(_ controller: PlayerVideoSurfaceController, context: Context) {
        controller.updateLayout(videoSize: videoSize, fillsScreen: fillsScreen)
        controller.mount(isActive ? videoView : nil)
    }
    static func dismantleUIViewController(_ controller: PlayerVideoSurfaceController, coordinator: ()) {
        controller.mount(nil)
    }
}

final class PlayerVideoSurfaceController: UIViewController {
    private weak var renderingView: UIView?
    private var mountingConstraints: [NSLayoutConstraint] = []
    private var renderingWidthConstraint: NSLayoutConstraint?
    private var renderingHeightConstraint: NSLayoutConstraint?
    private var videoSize: CGSize?
    private var fillsScreen = false
    private var rotationDisplayLink: CADisplayLink?
    private var rotationRevision = 0
    private typealias LayerGeometry = (layer: CALayer, bounds: CGRect, position: CGPoint)
    private var rotationFrames: [LayerGeometry] = []
    private var rotationStarted: CFTimeInterval = 0
    private var rotationDuration: TimeInterval = 0
    private var rotationTiming = CAMediaTimingFunction(name: .easeInEaseOut)
    private static let boundsAnimation = "vesper.videoRotation.bounds"
    private static let positionAnimation = "vesper.videoRotation.position"

    override func loadView() {
        let host = UIView()
        host.backgroundColor = .black
        host.clipsToBounds = true
        view = host
    }

    func updateLayout(videoSize: CGSize?, fillsScreen: Bool) {
        self.videoSize = videoSize
        self.fillsScreen = fillsScreen
        updateRenderingSize(for: view.bounds.size)
    }

    func mount(_ renderingView: UIView?) {
        loadViewIfNeeded()
        if self.renderingView === renderingView, renderingView == nil || renderingView?.superview === view { return }
        stopRotationSynchronization()
        NSLayoutConstraint.deactivate(mountingConstraints)
        mountingConstraints = []
        renderingWidthConstraint = nil
        renderingHeightConstraint = nil
        if self.renderingView?.superview === view { self.renderingView?.removeFromSuperview() }
        self.renderingView = renderingView
        guard let renderingView else { return }
        renderingView.removeFromSuperview()
        renderingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(renderingView)
        // Keep the active video content centered in the full-screen host.
        let width = renderingView.widthAnchor.constraint(equalToConstant: view.bounds.width)
        let height = renderingView.heightAnchor.constraint(equalToConstant: view.bounds.height)
        renderingWidthConstraint = width
        renderingHeightConstraint = height
        mountingConstraints = [
            renderingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            renderingView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            width,
            height
        ]
        NSLayoutConstraint.activate(mountingConstraints)
        updateRenderingSize(for: view.bounds.size)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        guard let renderingView, renderingView.superview === view,
              view.window != nil, coordinator.isAnimated, !UIAccessibility.isReduceMotionEnabled else { return }
        let frames = videoGeometryLayers(in: renderingView.layer).map { layer in
            let visible = layer.presentation() ?? layer
            return (layer: layer, bounds: visible.bounds, position: visible.position)
        }
        // Capture presentation geometry before cancelling an in-flight turn.
        stopRotationSynchronization()
        let revision = rotationRevision
        rotationFrames = frames
        // Both engines disable implicit actions when laying out their video
        // layers. UIKit animates the hosting view, but those layers otherwise
        // jump straight to the final bounds/position, moving the visible video
        // centre mid-rotation. Supply only the missing geometry animation,
        // using the same transition coordinator and retaining live playback.
        coordinator.animate(alongsideTransition: { [weak self] context in
            guard let self, self.rotationRevision == revision else { return }
            self.rotationStarted = CACurrentMediaTime()
            self.rotationDuration = context.transitionDuration
            self.rotationTiming = self.timingFunction(context.completionCurve)
            let link = CADisplayLink(target: RotationGeometryTick(owner: self), selector: #selector(RotationGeometryTick.tick(_:)))
            self.rotationDisplayLink = link
            link.add(to: .main, forMode: .common)
            self.updateRenderingSize(for: size)
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
            self.synchronizeVideoGeometry()
        }, completion: { [weak self] _ in
            guard let self, self.rotationRevision == revision else { return }
            self.stopRotationSynchronization()
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateRenderingSize(for: view.bounds.size)
        // SwiftUI may deliver the new viewport bounds after the coordinator's
        // animation block. Synchronize that later layout to the same clock.
        synchronizeVideoGeometry()
    }

    private func updateRenderingSize(for viewportSize: CGSize) {
        guard let renderingWidthConstraint, let renderingHeightConstraint,
              viewportSize.width > 0, viewportSize.height > 0 else { return }
        let rect = VideoViewportLayout.contentRect(
            sourceSize: videoSize,
            viewport: CGRect(origin: .zero, size: viewportSize),
            fillsScreen: fillsScreen
        )
        renderingWidthConstraint.constant = rect.width
        renderingHeightConstraint.constant = rect.height
    }

    private func synchronizeVideoGeometry() {
        guard rotationDuration > 0, CACurrentMediaTime() - rotationStarted < rotationDuration,
              let renderingView, renderingView.superview === view else { return }
        renderingView.layoutIfNeeded()
        // Engine layout can run independently of the host's layout callback.
        // Check each display tick, including intermediate container layers.
        // Animating only the final drawable leaves its parent free to jump.
        for frame in rotationFrames {
            guard contains(frame.layer, in: renderingView.layer) else { continue }
            let boundsKey = Self.boundsAnimation
            let positionKey = Self.positionAnimation
            let previousBounds = (frame.layer.animation(forKey: boundsKey) as? CABasicAnimation)?.toValue as? NSValue
            if frame.bounds != frame.layer.bounds, previousBounds?.cgRectValue != frame.layer.bounds {
                let animation = CABasicAnimation(keyPath: "bounds")
                animation.fromValue = NSValue(cgRect: frame.bounds)
                animation.toValue = NSValue(cgRect: frame.layer.bounds)
                configure(animation, for: frame.layer)
                frame.layer.add(animation, forKey: boundsKey)
            }
            let previousPosition = (frame.layer.animation(forKey: positionKey) as? CABasicAnimation)?.toValue as? NSValue
            if frame.position != frame.layer.position, previousPosition?.cgPointValue != frame.layer.position {
                let animation = CABasicAnimation(keyPath: "position")
                animation.fromValue = NSValue(cgPoint: frame.position)
                animation.toValue = NSValue(cgPoint: frame.layer.position)
                configure(animation, for: frame.layer)
                frame.layer.add(animation, forKey: positionKey)
            }
        }
    }

    private func configure(_ animation: CABasicAnimation, for layer: CALayer) {
        animation.duration = rotationDuration
        animation.beginTime = layer.convertTime(rotationStarted, from: nil)
        animation.timingFunction = rotationTiming
    }

    private func videoGeometryLayers(in root: CALayer) -> [CALayer] {
        func branch(_ layer: CALayer) -> [CALayer] {
            let descendants = (layer.sublayers ?? []).flatMap { branch($0) }
            let isVideo = layer is AVPlayerLayer || layer is AVSampleBufferDisplayLayer
                || layer is CAMetalLayer || layer is CAEAGLLayer
            return isVideo || !descendants.isEmpty ? [layer] + descendants : []
        }
        // The outer rendering view is already animated by UIKit constraints.
        // Include every internal ancestor of a drawable, not just the leaf.
        if root is AVPlayerLayer || root is AVSampleBufferDisplayLayer
            || root is CAMetalLayer || root is CAEAGLLayer {
            return branch(root)
        }
        return (root.sublayers ?? []).flatMap { branch($0) }
    }

    fileprivate func rotationGeometryTick(_ link: CADisplayLink) {
        guard rotationDuration > 0, CACurrentMediaTime() - rotationStarted < rotationDuration else {
            if rotationDisplayLink === link { stopRotationSynchronization() }
            else { link.invalidate() }
            return
        }
        synchronizeVideoGeometry()
    }

    private func stopRotationSynchronization() {
        // Also cancel coordinator callbacks queued for an unmounted surface.
        rotationRevision += 1
        rotationDisplayLink?.invalidate()
        rotationDisplayLink = nil
        rotationDuration = 0
        for frame in rotationFrames {
            frame.layer.removeAnimation(forKey: Self.boundsAnimation)
            frame.layer.removeAnimation(forKey: Self.positionAnimation)
        }
        rotationFrames = []
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopRotationSynchronization()
    }

    /// A display link must not retain the player controller after dismissal.
    @MainActor private final class RotationGeometryTick: NSObject {
        weak var owner: PlayerVideoSurfaceController?
        init(owner: PlayerVideoSurfaceController) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.rotationGeometryTick(link)
        }
    }
    private func contains(_ layer: CALayer, in root: CALayer) -> Bool {
        var candidate: CALayer? = layer
        while let current = candidate {
            if current === root { return true }
            candidate = current.superlayer
        }
        return false
    }
    private func timingFunction(_ curve: UIView.AnimationCurve) -> CAMediaTimingFunction {
        switch curve {
        case .easeIn: CAMediaTimingFunction(name: .easeIn)
        case .easeOut: CAMediaTimingFunction(name: .easeOut)
        case .linear: CAMediaTimingFunction(name: .linear)
        default: CAMediaTimingFunction(name: .easeInEaseOut)
        }
    }
}

private struct PlayerBufferMask: Shape {
    let segments: [ClosedRange<CGFloat>]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width.isFinite, rect.height.isFinite, !rect.isEmpty else { return path }
        for segment in segments where segment.lowerBound < segment.upperBound {
            let x = rect.minX + rect.width * segment.lowerBound
            let width = rect.width * (segment.upperBound - segment.lowerBound)
            path.addRect(CGRect(x: x, y: rect.minY, width: width, height: rect.height))
        }
        return path
    }
}
