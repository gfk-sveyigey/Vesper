import SwiftUI

/// Both settings entry points edit the same persisted values.
struct DanmakuPreferences: DynamicProperty {
    @AppStorage("danmaku.enabled") var enabled = true
    @AppStorage("danmaku.fontSize") var fontSize = 22.0
    @AppStorage("danmaku.opacity") var opacity = 0.85
    @AppStorage("danmaku.speed") var speed = 1.0
    @AppStorage("danmaku.area") var area = 0.5
    @AppStorage("danmaku.density") var density = 2
    @AppStorage("danmaku.scrolling") var scrolling = true
    @AppStorage("danmaku.top") var top = true
    @AppStorage("danmaku.bottom") var bottom = true
    @AppStorage("danmaku.colored") var colored = true
    @AppStorage("danmaku.bold") var bold = false
    @AppStorage("danmaku.shadow") var shadow = true
    @AppStorage("danmaku.avoidSubtitles") var avoidSubtitles = true
    @AppStorage("danmaku.filterDuplicates") var filterDuplicates = true
    @AppStorage("danmaku.blockedWords") var blockedWords = ""

    var options: DanmakuDisplayOptions {
        .init(fontSize: fontSize, speed: speed, area: area, density: density,
              scrolling: scrolling, top: top, bottom: bottom, colored: colored,
              bold: bold, shadow: shadow, avoidSubtitles: avoidSubtitles,
              filterDuplicates: filterDuplicates, blockedWords: blockedWords)
    }
    var layoutKey: String {
        "\(fontSize)-\(speed)-\(area)-\(density)-\(scrolling)-\(top)-\(bottom)-\(bold)-\(avoidSubtitles)-\(filterDuplicates)-\(blockedWords)"
    }
}

struct DanmakuPreferenceSections: View {
    var showsSourceManagement = false
    @ObservedObject private var sources = DanmakuAPISources.shared
    private var preferences = DanmakuPreferences()
    @State private var confirmingReset = false
    var body: some View {
        SettingsSection {
            Toggle("显示弹幕", isOn: preferences.$enabled)
        } footer: {
            Text("对所有视频生效，画中画暂不显示弹幕。")
        }
        if showsSourceManagement {
            SettingsSection("弹幕来源") {
                NavigationLink {
                    DanmakuAPISettingsView()
                } label: {
                    HStack {
                        Label("弹幕 API", systemImage: "network")
                        Spacer()
                        Text("\(sources.sources.count) 个")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } footer: {
                Text("在播放界面搜索在线弹幕或导入本地 XML 文件。")
            }
        }
        appearance
        movement
        types
        filtering
        SettingsSection {
            Button("恢复默认弹幕设置") { confirmingReset = true }
        } footer: {
            Text("仅恢复显示与过滤偏好，保留弹幕、API 配置和当前视频的时间偏移。")
        }
        .confirmationDialog("恢复默认弹幕设置？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("恢复默认设置") { reset() }
            Button("取消", role: .cancel) {}
        }
    }
    private var appearance: some View {
        SettingsSection("文字样式") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("字号")
                    Spacer()
                    Text("\(Int(preferences.fontSize))").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: preferences.$fontSize, in: 14...40, step: 1)
                    .accessibilityLabel("弹幕字号")
            }.padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("不透明度")
                    Spacer()
                    Text("\(Int(preferences.opacity * 100))%")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: preferences.$opacity, in: 0.1...1, step: 0.05)
                    .accessibilityLabel("弹幕不透明度")
            }.padding(.vertical, 6)
            Toggle("保留弹幕颜色", isOn: preferences.$colored)
            Toggle("粗体", isOn: preferences.$bold)
            Toggle("文字阴影", isOn: preferences.$shadow)
        }
    }
    private var movement: some View {
        SettingsSection("布局与速度") {
            SettingsPicker("显示区域", selection: preferences.$area) {
                Text("顶部四分之一").tag(0.25)
                Text("顶部一半").tag(0.5)
                Text("顶部四分之三").tag(0.75)
                Text("全屏").tag(1.0)
            }
            SettingsPicker("弹幕密度", selection: preferences.$density) {
                Text("低").tag(1); Text("中").tag(2); Text("高").tag(3)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("弹幕速度")
                    Spacer()
                    Text(String(format: "%.2f×", preferences.speed))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: preferences.$speed, in: 0.5...2, step: 0.25)
                    .accessibilityLabel("弹幕速度")
            }.padding(.vertical, 6)
            Toggle("避让底部字幕区域", isOn: preferences.$avoidSubtitles)
        } footer: {
            Text("速度随视频倍速变化；字幕避让为底部预留空间。轨道满时自动减少显示，避免重叠。")
        }
    }
    private var types: some View {
        SettingsSection("弹幕类型") {
            Toggle("滚动弹幕", isOn: preferences.$scrolling)
            Toggle("顶部固定弹幕", isOn: preferences.$top)
            Toggle("底部固定弹幕", isOn: preferences.$bottom)
        }
    }
    private var filtering: some View {
        SettingsSection("内容过滤") {
            Toggle("过滤重复弹幕", isOn: preferences.$filterDuplicates)
            VStack(alignment: .leading, spacing: 8) {
                Text("屏蔽关键词").font(.subheadline)
                TextField("每行一个，或用逗号分隔", text: preferences.$blockedWords, axis: .vertical)
                    .lineLimit(3...6)
                    .autocorrectionDisabled()
            }.padding(.vertical, 6)
        } footer: {
            Text("关键词用换行、逗号或分号分隔，不区分大小写，按包含关系屏蔽。重复过滤会隐藏 10 秒内相同文字的弹幕，不删除原始数据。")
        }
    }
    private func reset() {
        preferences.enabled = true; preferences.fontSize = 22; preferences.opacity = 0.85
        preferences.speed = 1; preferences.area = 0.5; preferences.density = 2
        preferences.scrolling = true; preferences.top = true; preferences.bottom = true
        preferences.colored = true; preferences.bold = false; preferences.shadow = true
        preferences.avoidSubtitles = true; preferences.filterDuplicates = true; preferences.blockedWords = ""
    }
}
