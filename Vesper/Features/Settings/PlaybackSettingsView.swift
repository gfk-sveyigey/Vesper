import SwiftUI

enum PlaybackPreferences {
    static var preferredDecoder: PlaybackDecoder { PlaybackDecoder(rawValue: UserDefaults.standard.string(forKey: "player.decoder") ?? "hardware") ?? .hardware }
    static var backgroundEnabled: Bool { UserDefaults.standard.object(forKey: "player.background.enabled") as? Bool ?? true }
    static var backgroundMode: String { UserDefaults.standard.string(forKey: "player.background.mode") ?? "audio" }
    static var remembersProgress: Bool { UserDefaults.standard.object(forKey: "player.rememberProgress") as? Bool ?? true }
}

enum PlaybackDecoder: String, CaseIterable, Identifiable {
    case hardware, software
    var id: Self { self }
    var title: String { self == .hardware ? "硬件解码" : "软件解码" }
}

struct PlaybackSettingsView: View {
    @ObservedObject var session: PlaybackSession
    @AppStorage("player.background.enabled") private var backgroundEnabled = true
    @AppStorage("player.background.mode") private var backgroundMode = "audio"
    @AppStorage("player.decoder") private var decoder = PlaybackDecoder.hardware
    @AppStorage("player.playbackRate") private var defaultRate = 1.0
    @AppStorage("player.rememberProgress") private var remembersProgress = true
    @AppStorage("player.gesture.skipSeconds") private var skipSeconds = 15.0
    var body: some View {
        SettingsPage {
            Group {
                SettingsIntroCard(title: "播放设置", symbol: "play.circle", description: "管理后台播放、进度与跳转。")
                SettingsSection {
                    SettingsPicker("优先解码方式", selection: $decoder) {
                        ForEach(PlaybackDecoder.allCases) { mode in
                            Text(LocalizedStringKey(mode.title)).tag(mode)
                        }
                    }
                    Toggle("后台播放", isOn: $backgroundEnabled)
                    SettingsPicker("后台播放方式", selection: $backgroundMode) {
                        Text("音频播放").tag("audio")
                        Text("画中画播放").tag("pip")
                    }
                    .pickerStyle(.menu)
                    .disabled(!backgroundEnabled)
                    Toggle("保留播放进度", isOn: $remembersProgress)
                    SettingsPicker("快进快退时长", selection: $skipSeconds) {
                        ForEach([5.0, 10, 15, 30], id: \.self) { seconds in
                            Text(verbatim: String(format: VesperLocalization.string("%d 秒"), Int(seconds))).tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                    SettingsPicker("默认播放速度", selection: $defaultRate) {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                            Text(verbatim: String(format: "%g×", Double(rate))).tag(rate)
                        }
                    }
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .background(VesperTheme.background)
        .navigationTitle("播放设置")
        .toolbarTitleDisplayMode(.inline)
        .onAppear { session.setBackgroundPreferences(enabled: backgroundEnabled, mode: backgroundMode) }
        .onChange(of: backgroundEnabled) { _, value in session.setBackgroundPreferences(enabled: value, mode: backgroundMode) }
        .onChange(of: backgroundMode) { _, value in session.setBackgroundPreferences(enabled: backgroundEnabled, mode: value) }
        .onChange(of: remembersProgress) { _, enabled in
            if !enabled { session.clearSavedProgress() }
        }
    }
}

struct SubtitleSettingsView: View {
    @AppStorage("player.subtitle.fontSize") private var fontSize = 22.0
    @AppStorage("player.subtitle.background") private var showsBackground = true
    var body: some View {
        SettingsPage {
            Group {
                SettingsIntroCard(title: "字幕设置", symbol: "captions.bubble", description: "调整字幕字号与背景。")
                SettingsSection {
                    SettingsPicker("字幕字号", selection: $fontSize) {
                        ForEach([18.0, 20, 22, 24, 28, 32], id: \.self) { size in
                            Text(verbatim: String(format: "%g", size)).tag(size)
                        }
                    }
                    Toggle("字幕背景", isOn: $showsBackground)
                } footer: {
                    Text("在播放器的字幕菜单中选择视频内的字幕轨道。字号和背景设置应用于文字字幕。")
                }
                SettingsSection {
                    Text("字幕预览")
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 2)
                        .padding(8)
                        .background(.black.opacity(showsBackground ? 0.6 : 0), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .background(VesperTheme.background)
        .navigationTitle("字幕设置")
        .toolbarTitleDisplayMode(.inline)
    }
}

struct DanmakuSettingsView: View {
    var body: some View {
        SettingsPage {
            Group {
                SettingsIntroCard(title: "弹幕设置", symbol: "text.bubble", description: "管理播放弹幕。")
                SettingsSection { Text("尚未接入弹幕来源。").foregroundStyle(.secondary) }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .background(VesperTheme.background)
        .navigationTitle("弹幕设置")
        .toolbarTitleDisplayMode(.inline)
    }
}
