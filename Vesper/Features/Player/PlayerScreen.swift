import SwiftUI
import UIKit

struct PlayerScreen: View {
    @ObservedObject var session: PlaybackSession
    @State private var scrubTime: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ZStack {
                    Color.black
                    if let view = session.videoView {
                        PlayerVideoSurface(videoView: view)
                    }
                    if session.isLoading { ProgressView().tint(.white) }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                if let message = session.errorMessage {
                    ContentUnavailableView {
                        Label("无法播放", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(verbatim: message)
                    } actions: {
                        Button("重试") { session.retry() }
                    }
                } else if session.currentItem == nil {
                    ContentUnavailableView("未在播放", systemImage: "play.rectangle",
                        description: Text("选择媒体后即可开始播放。"))
                } else {
                    VStack(spacing: 8) {
                        Slider(value: $scrubTime, in: 0...max(session.duration, 1)) { editing in
                            isScrubbing = editing
                            if !editing { session.seek(to: scrubTime) }
                        }
                        .disabled(!session.canSeek)
                        .accessibilityLabel("播放进度")
                        HStack {
                            Text(timeLabel(isScrubbing ? scrubTime : session.currentTime))
                            Spacer()
                            Text(timeLabel(session.duration))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 40) {
                        Button("后退15秒", systemImage: "gobackward.15") { session.seek(to: session.currentTime - 15) }
                            .disabled(!session.canSeek)
                        Button(session.isPlaying ? "暂停" : "播放", systemImage: session.isPlaying ? "pause.fill" : "play.fill") {
                            session.togglePlayback()
                        }
                        .font(.largeTitle)
                        .disabled(!session.canControl)
                        Button("前进15秒", systemImage: "goforward.15") { session.seek(to: session.currentTime + 15) }
                            .disabled(!session.canSeek)
                        Button("下一项", systemImage: "forward.end.fill") { session.next() }
                            .disabled(!session.hasNext)
                    }
                    .labelStyle(.iconOnly)
                    .font(.title2)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle(session.currentItem?.title ?? String(localized: "播放器"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("收起", systemImage: "chevron.down") { session.isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("停止播放", systemImage: "stop.fill") { session.stop() }
                        .disabled(session.currentItem == nil)
                }
            }
        }
        .onAppear { scrubTime = session.currentTime }
        .onChange(of: session.currentTime) { _, time in
            if !isScrubbing { scrubTime = min(time, max(session.duration, 1)) }
        }
        .onChange(of: session.currentItem?.id) { _, _ in isScrubbing = false; scrubTime = 0 }
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
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
