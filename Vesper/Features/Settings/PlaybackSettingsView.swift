import SwiftUI

enum PlaybackPreferences {
    static var backgroundEnabled: Bool { UserDefaults.standard.object(forKey: "player.background.enabled") as? Bool ?? true }
    static var backgroundMode: String { UserDefaults.standard.string(forKey: "player.background.mode") ?? "audio" }
    static var resumeOnForeground: Bool { UserDefaults.standard.object(forKey: "player.resumeOnForeground") as? Bool ?? true }
    static var remembersProgress: Bool { UserDefaults.standard.object(forKey: "player.rememberProgress") as? Bool ?? true }
}

struct PlaybackSettingsView: View {
    @ObservedObject var session: PlaybackSession
    @AppStorage("player.background.enabled") private var backgroundEnabled = true
    @AppStorage("player.background.mode") private var backgroundMode = "audio"
    @AppStorage("player.resumeOnForeground") private var resumeOnForeground = true
    @AppStorage("player.rememberProgress") private var remembersProgress = true
    @AppStorage("player.gesture.skipSeconds") private var skipSeconds = 15.0
    var body: some View {
        Form {
            Group {
                SettingsIntroCard(title: "播放设置", symbol: "play.circle", description: "管理后台播放、进度与跳转。")
                Section {
                    Toggle("后台播放", isOn: $backgroundEnabled)
                    Picker("后台播放方式", selection: $backgroundMode) {
                        Text("音频播放").tag("audio")
                        Text("画中画播放").tag("pip")
                    }
                    .pickerStyle(.menu)
                    .disabled(!backgroundEnabled)
                    Toggle("回到前台自动续播", isOn: $resumeOnForeground)
                    Toggle("保留播放进度", isOn: $remembersProgress)
                    Picker("快进快退时长", selection: $skipSeconds) {
                        ForEach([5.0, 10, 15, 30], id: \.self) { seconds in
                            Text(verbatim: String(format: VesperLocalization.string("%d 秒"), Int(seconds))).tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("播放速度", selection: Binding(get: { session.playbackRate }, set: { session.setPlaybackRate($0) })) {
                        ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                            Text(verbatim: String(format: "%g×", Double(rate))).tag(rate)
                        }
                    }
                }
            }
            .listRowBackground(VesperTheme.background)
        }
        .listSectionSpacing(28)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(VesperTheme.background)
        .navigationTitle("播放设置")
        .toolbarTitleDisplayMode(.inline)
        .onChange(of: backgroundEnabled) { _, _ in session.refreshPlaybackPreferences() }
        .onChange(of: backgroundMode) { _, _ in session.refreshPlaybackPreferences() }
        .onChange(of: remembersProgress) { _, enabled in
            if !enabled { session.clearSavedProgress() }
        }
    }
}

struct SubtitleSettingsView: View {
    @AppStorage("player.subtitle.fontSize") private var fontSize = 22.0
    @AppStorage("player.subtitle.background") private var showsBackground = true
    var body: some View {
        Form {
            Group {
                SettingsIntroCard(title: "字幕设置", symbol: "captions.bubble", description: "调整字幕字号与背景。")
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
        .listSectionSpacing(28)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(VesperTheme.background)
        .navigationTitle("字幕设置")
        .toolbarTitleDisplayMode(.inline)
    }
}

struct DanmakuSettingsView: View {
    var body: some View {
        List {
            Group {
                SettingsIntroCard(title: "弹幕设置", symbol: "text.bubble", description: "管理播放弹幕。")
                Section { Text("尚未接入弹幕来源。").foregroundStyle(.secondary) }
            }
            .listRowBackground(VesperTheme.background)
        }
        .listSectionSpacing(28)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(VesperTheme.background)
        .navigationTitle("弹幕设置")
        .toolbarTitleDisplayMode(.inline)
    }
}
