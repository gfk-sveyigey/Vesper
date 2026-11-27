import SwiftUI

enum PlaybackPreferences {
    static var preferredEngine: PlaybackEngine {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "player.engine"), let value = PlaybackEngine(rawValue: raw) { return value }
        // Removed engines are intentionally not mapped to an unrelated backend.
        defaults.set(PlaybackEngine.aether.rawValue, forKey: "player.engine")
        return .aether
    }
    static var preferredDecoder: PlaybackDecoder { PlaybackDecoder(rawValue: UserDefaults.standard.string(forKey: "player.decoder") ?? "hardware") ?? .hardware }
    static var backgroundEnabled: Bool { UserDefaults.standard.object(forKey: "player.background.enabled") as? Bool ?? true }
    static var backgroundMode: String { UserDefaults.standard.string(forKey: "player.background.mode") ?? "audio" }
    static var remembersProgress: Bool { UserDefaults.standard.object(forKey: "player.rememberProgress") as? Bool ?? true }
    static var showsRemainingDuration: Bool { UserDefaults.standard.object(forKey: "player.showsRemainingDuration") as? Bool ?? false }
    static let preciseSeekingKey = "player.preciseSeeking"
    static var preciseSeeking: Bool { UserDefaults.standard.bool(forKey: preciseSeekingKey) }
    static let alwaysShowsMoreControlsKey = "player.alwaysShowsMoreControls"
}

enum PlaybackEngine: String, CaseIterable, Identifiable {
    case aether, vlc
    var id: Self { self }
    var title: String { self == .vlc ? "SwiftVLC" : "AetherEngine" }
}

enum PlaybackDecoder: String, CaseIterable, Identifiable {
    case hardware, software
    var id: Self { self }
    var title: String { self == .hardware ? "硬件解码" : "软件解码" }
}

struct PlaybackSettingsView: View {
    @ObservedObject var session: PlaybackSession
    @AppStorage("miniPlayer.enabled") private var miniPlayerEnabled = true
    @AppStorage("miniPlayer.alwaysVisible") private var miniPlayerAlwaysVisible = true
    @AppStorage("player.background.enabled") private var backgroundEnabled = true
    @AppStorage("player.background.mode") private var backgroundMode = "audio"
    @AppStorage("player.engine") private var engine = PlaybackEngine.aether
    @AppStorage("player.decoder") private var decoder = PlaybackDecoder.hardware
    @AppStorage("player.playbackRate") private var defaultRate = 1.0
    @AppStorage("player.rememberProgress") private var remembersProgress = true
    @AppStorage("player.showsRemainingDuration") private var showsRemainingDuration = false
    @AppStorage("player.gesture.skipSeconds") private var skipSeconds = 15.0
    @AppStorage(PlaybackPreferences.preciseSeekingKey) private var preciseSeeking = false
    @AppStorage(PlaybackPreferences.alwaysShowsMoreControlsKey) private var alwaysShowsMoreControls = false
    var body: some View {
        SettingsPage {
            Group {
                SettingsIntroCard(title: "播放设置", symbol: "play.circle", description: "设置默认内核与解码方式，调整后台播放、迷你播放器、续播和播放速度。")
                SettingsSection {
                    SettingsPicker("默认播放内核", selection: $engine) {
                        ForEach(PlaybackEngine.allCases) { mode in Text(verbatim: mode.title).tag(mode) }
                    }
                    SettingsPicker("优先解码方式", selection: $decoder) {
                        ForEach(PlaybackDecoder.allCases) { mode in
                            Text(LocalizedStringKey(mode.title)).tag(mode)
                        }
                    }
                }
                SettingsSection {
                    Toggle("后台播放", isOn: $backgroundEnabled)
                    SettingsPicker("后台播放方式", selection: $backgroundMode) {
                        Text("音频播放").tag("audio")
                        Text("画中画播放").tag("pip")
                    }
                    .pickerStyle(.menu)
                    .disabled(!backgroundEnabled)
                }
                SettingsSection {
                    Toggle("启用迷你播放器", isOn: $miniPlayerEnabled)
                    if #available(iOS 26.1, *) {
                        Toggle("常显迷你播放器", isOn: $miniPlayerAlwaysVisible)
                        .disabled(!miniPlayerEnabled)
                    }
                } footer: {
                    Text("关闭常显后，仅在有可播放内容时显示迷你播放器。")
                }
                SettingsSection {
                    Toggle("按进度续播", isOn: $remembersProgress)
                    Toggle("精准定位", isOn: $preciseSeeking)
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
                SettingsSection {
                    Toggle("显示剩余时长", isOn: $showsRemainingDuration)
                } footer: {
                    Text("关闭时显示视频总时长；开启后显示剩余时长。")
                }
                SettingsSection {
                    Toggle("常显更多控制按钮", isOn: $alwaysShowsMoreControls)
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
    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "字幕设置", symbol: "captions.bubble", description: "字幕由播放引擎显示，请在播放界面调整当前引擎支持的字幕选项。")
            SettingsSection {
                Text("请在播放界面打开字幕设置。可调整的选项随当前播放引擎及字幕格式变化。")
            }
        }
        .navigationTitle("字幕设置")
        .toolbarTitleDisplayMode(.inline)
    }
}

struct PlayerSubtitleSettingsView: View {
    @ObservedObject var session: PlaybackSession
    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "字幕设置", symbol: "captions.bubble", description: "调整当前内核支持的字幕显示与同步选项。")
            SettingsSection {
                LabeledContent("播放内核", value: session.currentEngine.title)
            }
            if session.currentEngine == .vlc {
                SettingsSection("SwiftVLC 字幕") {
                    Slider(value: Binding(get: { session.subtitleSize }, set: { session.setSubtitleSize($0) }), in: 14...40, step: 1)
                    LabeledContent("字幕字号", value: String(format: "%.0f", session.subtitleSize))
                    Stepper(value: Binding(get: { session.subtitleDelay }, set: { session.setSubtitleDelay($0) }), in: -30...30, step: 0.1) {
                        LabeledContent("字幕延迟", value: String(format: VesperLocalization.string("%+.1f 秒"), session.subtitleDelay))
                    }
                } footer: {
                    Text("正值延后，负值提前。延迟适用于内嵌和外挂字幕；字号缩放以 VLC 和字幕格式支持为准，图片字幕不能修改字体。")
                }
            } else {
                SettingsSection("Aether 字幕") {
                    Slider(value: Binding(get: { session.subtitleSize }, set: { session.setSubtitleSize($0) }), in: 14...40, step: 1)
                    LabeledContent("字幕字号", value: String(format: "%.0f", session.subtitleSize))
                } footer: {
                    Text("字号仅用于支持样式覆盖的原生文本字幕，软件路径或图片字幕可能不生效。当前引擎没有跨播放路径通用的字幕延迟接口，暂不提供延迟调整。")
                }
            }
        }
        .navigationTitle("字幕设置")
        .toolbarTitleDisplayMode(.inline)
    }
}

struct DanmakuSettingsView: View {
    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "弹幕设置", symbol: "text.bubble",
                              description: "调整弹幕字号、速度、透明度和显示区域，管理屏蔽规则与在线 API。")
            DanmakuPreferenceSections(showsSourceManagement: true)
        }
        .navigationTitle("弹幕设置")
        .toolbarTitleDisplayMode(.inline)
    }
}
