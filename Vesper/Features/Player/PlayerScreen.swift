import SwiftUI
import UIKit

private enum PlayerPanel: String, Identifiable {
    case settings, tracks, queue
    var id: String { rawValue }
}

struct PlayerScreen: View {
    @ObservedObject var session: PlaybackSession
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controlsVisible = true
    @State private var autoHideRevision = 0
    @State private var scrubTime: Double = 0
    @State private var isScrubbing = false
    @State private var resumeAfterScrub = false
    @State private var panel: PlayerPanel?
    @State private var rotationScene: UIWindowScene?
    @State private var rotationError: String?
    @State private var isShowingRotationError = false

    private var canAutoHide: Bool {
        controlsVisible && session.isPlaying && !session.isLoading && !session.isSeeking
            && !isScrubbing && panel == nil && !voiceOver && session.errorMessage == nil
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if let view = session.videoView {
                    PlayerVideoSurface(videoView: view)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1))
                        .onEnded { event in
                            switch event {
                            case .first:
                                session.togglePlayback()
                                revealControls()
                            case .second:
                                if voiceOver { revealControls() }
                                else { setControlsVisible(!controlsVisible) }
                            }
                        })
                    .accessibilityHidden(true)
                subtitles(landscape: landscape)
                    .allowsHitTesting(false)
                if controlsVisible {
                    LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.8)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea().allowsHitTesting(false)
                    VStack(spacing: 0) {
                        topControls
                        Spacer(minLength: 0)
                        if session.errorMessage == nil, session.currentItem != nil,
                           !session.isLoading, !session.isSeeking {
                            transportControls
                        }
                        Spacer(minLength: 0)
                        bottomControls(landscape: landscape)
                    }
                    .padding(.horizontal, landscape ? 28 : 20)
                    .padding(.vertical, 12)
                }
                if session.isLoading || session.isSeeking {
                    ProgressView().controlSize(.large).tint(.white)
                        .allowsHitTesting(false)
                        .accessibilityLabel("正在加载")
                }
                if let message = session.errorMessage {
                    errorContent(message)
                } else if session.currentItem == nil {
                    Text("未在播放").foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.white)
            .tint(.white)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .visible : .hidden)
        .sheet(item: $panel, onDismiss: revealControls) { selected in
            panelContent(selected)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .alert("无法旋转屏幕", isPresented: $isShowingRotationError) {
            Button("好", role: .cancel) { }
        } message: { Text(verbatim: rotationError ?? "") }
        .onAppear {
            scrubTime = session.currentTime
            revealControls()
        }
        .onDisappear {
            if isScrubbing {
                session.seek(to: scrubTime, resume: resumeAfterScrub)
                isScrubbing = false
            }
            if let scene = rotationScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
        .onChange(of: session.currentTime) { _, time in
            if !isScrubbing { scrubTime = min(time, max(session.duration, 1)) }
        }
        .onChange(of: session.currentItem?.id) { _, _ in
            isScrubbing = false
            scrubTime = 0
            revealControls()
        }
        .onChange(of: session.isPlaying) { _, playing in
            if !playing { revealControls() }
            else { autoHideRevision += 1 }
        }
        .onChange(of: session.isLoading) { _, _ in autoHideRevision += 1 }
        .onChange(of: session.isSeeking) { _, _ in autoHideRevision += 1 }
        .onChange(of: session.errorMessage) { _, message in if message != nil { revealControls() } }
        .onChange(of: voiceOver) { _, _ in revealControls() }
        .onChange(of: panel) { _, _ in revealControls() }
        .task(id: autoHideRevision) {
            guard canAutoHide else { return }
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard !Task.isCancelled, canAutoHide else { return }
            setControlsVisible(false)
        }
    }

    private var topControls: some View {
        HStack(spacing: 12) {
            control("收起", symbol: "chevron.down") { session.isPresented = false }
            Text(verbatim: session.currentItem?.title ?? String(localized: "播放器"))
                .font(.headline).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            control("更多", symbol: "ellipsis") { panel = .settings }
        }
    }

    private var transportControls: some View {
        HStack(spacing: 40) {
            control("后退15秒", symbol: "gobackward.15", size: 54) {
                session.seek(to: session.currentTime - 15)
            }.disabled(!session.canSeek)
            control(session.isPlaying ? "暂停" : "播放",
                    symbol: session.isPlaying ? "pause.fill" : "play.fill", size: 76) {
                session.togglePlayback()
            }.disabled(!session.canControl)
            control("前进15秒", symbol: "goforward.15", size: 54) {
                session.seek(to: session.currentTime + 15)
            }.disabled(!session.canSeek)
        }
    }

    private func bottomControls(landscape: Bool) -> some View {
        VStack(spacing: 6) {
            if isScrubbing {
                Text(timeLabel(scrubTime)).font(.headline.monospacedDigit())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
            }
            ZStack {
                GeometryReader { geometry in
                    Capsule().fill(.white.opacity(0.2))
                        .frame(width: geometry.size.width * bufferedFraction, height: 3)
                        .frame(maxHeight: .infinity)
                }
                .padding(.horizontal, 2)
                .allowsHitTesting(false)
                Slider(value: $scrubTime, in: 0...max(session.duration, 1), onEditingChanged: scrubChanged)
                    .disabled(!session.canSeek)
                    .accessibilityLabel("播放进度")
                    .accessibilityValue(timeLabel(isScrubbing ? scrubTime : session.currentTime))
            }
            .frame(height: 32)
            HStack {
                Text(timeLabel(isScrubbing ? scrubTime : session.currentTime))
                Spacer()
                Text(timeLabel(session.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
            HStack(spacing: landscape ? 20 : 8) {
                Button {
                    revealControls()
                    panel = .settings
                } label: {
                    Text(rateLabel).font(.subheadline.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("播放速度")
                .accessibilityValue(rateLabel)
                control("字幕与音轨", symbol: "captions.bubble") { panel = .tracks }
                control("播放列表", symbol: "list.bullet") { panel = .queue }
                    .disabled(session.queue.isEmpty)
                Spacer(minLength: 0)
                control(session.fillsScreen ? "完整显示" : "填满屏幕",
                        symbol: session.fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    session.toggleFill()
                }
                control(landscape ? "竖屏" : "横屏", symbol: landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate") {
                    rotate(landscape: !landscape)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var bufferedFraction: CGFloat {
        guard session.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, session.bufferedTime / session.duration)))
    }

    private func subtitles(landscape: Bool) -> some View {
        VStack {
            Spacer()
            if let image = session.subtitleImage {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxHeight: landscape ? 100 : 180)
            }
            if !session.subtitleText.isEmpty {
                Text(verbatim: session.subtitleText)
                    .font(.system(size: landscape ? 22 : 20, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 2, x: 1, y: 1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, controlsVisible ? 155 : 24)
        .frame(maxWidth: .infinity)
    }

    private func control(_ title: LocalizedStringKey, symbol: String, size: CGFloat = 44,
                         action: @escaping () -> Void) -> some View {
        Button {
            revealControls()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size == 76 ? 36 : (size == 54 ? 27 : 18), weight: .semibold))
                .frame(width: size, height: size)
                .background(.black.opacity(0.25), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private func errorContent(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text("无法播放").font(.headline)
            Text(verbatim: message).font(.subheadline).multilineTextAlignment(.center)
            Button("重试") { session.retry(); revealControls() }.buttonStyle(.borderedProminent)
        }
        .padding(24).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 30)
    }

    private func panelContent(_ selected: PlayerPanel) -> some View {
        NavigationStack {
            List {
                switch selected {
                case .settings:
                    Section("播放速度") {
                        ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                            Button {
                                session.setPlaybackRate(rate)
                            } label: {
                                selectionRow(String(format: "%g×", Double(rate)), selected: session.playbackRate == rate)
                            }
                        }
                    }
                    Section("画面") {
                        Button {
                            session.toggleFill()
                        } label: {
                            Label(session.fillsScreen ? "完整显示" : "填满屏幕", systemImage: "aspectratio")
                        }
                    }
                    Section {
                        Button("停止播放", role: .destructive) { panel = nil; session.stop() }
                    }
                case .tracks:
                    Section("音轨") {
                        if session.audioTracks.isEmpty { Text("无可用音轨").foregroundStyle(.secondary) }
                        ForEach(session.audioTracks) { track in
                            Button { session.selectAudio(track.id) } label: {
                                selectionRow(track.name, selected: track.isSelected)
                            }
                        }
                    }
                    Section("字幕") {
                        Button { session.selectSubtitle(nil) } label: {
                            selectionRow(String(localized: "关闭字幕"), selected: session.selectedSubtitleID == nil)
                        }
                        if session.subtitleTracks.isEmpty { Text("无内嵌字幕").foregroundStyle(.secondary) }
                        ForEach(session.subtitleTracks) { track in
                            Button { session.selectSubtitle(track.id) } label: {
                                selectionRow(track.name, selected: track.isSelected)
                            }
                        }
                    }
                case .queue:
                    ForEach(session.queue) { item in
                        Button {
                            session.playQueued(item)
                            panel = nil
                        } label: {
                            selectionRow(item.title, selected: item.id == session.currentItem?.id)
                        }
                    }
                }
            }
            .navigationTitle(panelTitle(selected))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { panel = nil }
                }
            }
        }
    }

    private func selectionRow(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(verbatim: title).lineLimit(2)
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func panelTitle(_ selected: PlayerPanel) -> LocalizedStringKey {
        switch selected {
        case .settings: "播放设置"
        case .tracks: "字幕与音轨"
        case .queue: "播放列表"
        }
    }

    private var rateLabel: String { String(format: "%g×", Double(session.playbackRate)) }

    private func scrubChanged(_ editing: Bool) {
        if editing {
            resumeAfterScrub = session.isPlaying
            isScrubbing = true
            session.pause()
        } else {
            isScrubbing = false
            session.seek(to: scrubTime, resume: resumeAfterScrub)
        }
        revealControls()
    }

    private func revealControls() { setControlsVisible(true) }

    private func setControlsVisible(_ visible: Bool) {
        autoHideRevision += 1
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            controlsVisible = visible
        }
    }

    private func rotate(landscape: Bool) {
        guard let scene = session.videoView?.window?.windowScene else { return }
        rotationScene = scene
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscape : .portrait)) { error in
            Task { @MainActor in
                rotationError = error.localizedDescription
                isShowingRotationError = true
                revealControls()
            }
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
private struct PlayerVideoSurface: UIViewRepresentable {
    let videoView: UIView

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ host: UIView, context: Context) {
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
