import SwiftUI

struct PlaybackSettingsView: View {
    @ObservedObject var session: PlaybackSession
    var body: some View {
        Form {
            Group {
                Section {
                    Picker("播放速度", selection: Binding(get: { session.playbackRate }, set: { session.setPlaybackRate($0) })) {
                        ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                            Text(verbatim: String(format: "%g×", Double(rate))).tag(rate)
                        }
                    }
                }
                Section {
                    NavigationLink("字幕设置") { SubtitleSettingsView() }
                    NavigationLink("弹幕设置") { DanmakuSettingsView() }
                    NavigationLink("播放手势") { PlayerGestureSettingsView() }
                }
            }
            .listRowBackground(VesperTheme.background)
        }
        .scrollContentBackground(.hidden)
        .background(VesperTheme.background)
        .navigationTitle("播放设置")
        .toolbarTitleDisplayMode(.inline)
    }
}

struct SubtitleSettingsView: View {
    @AppStorage("player.subtitle.fontSize") private var fontSize = 22.0
    @AppStorage("player.subtitle.background") private var showsBackground = true
    var body: some View {
        Form {
            Group {
                Section {
                    Picker("字幕字号", selection: $fontSize) {
                        ForEach([18.0, 20, 22, 24, 28, 32], id: \.self) { size in
                            Text(verbatim: String(format: "%g", size)).tag(size)
                        }
                    }
                    Toggle("字幕背景", isOn: $showsBackground)
                } footer: {
                    Text("在播放器的字幕菜单中选择视频内的字幕轨道。字号和背景设置应用于文字字幕。")
                }
                Section {
                    Text("字幕预览")
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .padding(8)
                        .background(.black.opacity(showsBackground ? 0.6 : 0), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .listRowBackground(VesperTheme.background)
        }
        .scrollContentBackground(.hidden)
        .background(VesperTheme.background)
        .navigationTitle("字幕设置")
        .toolbarTitleDisplayMode(.inline)
    }
}

struct DanmakuSettingsView: View {
    var body: some View {
        ContentUnavailableView("弹幕设置", systemImage: "text.bubble", description: Text("尚未接入弹幕来源。"))
            .background(VesperTheme.background)
            .navigationTitle("弹幕设置")
            .toolbarTitleDisplayMode(.inline)
    }
}
