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
    private var preferences = DanmakuPreferences()
    @State private var confirmingReset = false
    var body: some View {
        appearance
        movement
        filtering
        Section {
            Button("恢复默认弹幕设置") { confirmingReset = true }
        } footer: {
            Text("设置对所有视频生效。不会移除当前弹幕、API 配置或修改当前视频的时间偏移。画中画暂不显示弹幕。")
        }
        .confirmationDialog("恢复默认弹幕设置？", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("恢复默认设置") { reset() }
            Button("取消", role: .cancel) {}
        }
    }
    private var appearance: some View {
        Section("显示与样式") {
            Toggle("显示弹幕", isOn: preferences.$enabled)
            LabeledContent("字号", value: "\(Int(preferences.fontSize))")
            Slider(value: preferences.$fontSize, in: 14...40, step: 1)
            LabeledContent("不透明度", value: "\(Int(preferences.opacity * 100))%")
            Slider(value: preferences.$opacity, in: 0.1...1, step: 0.05)
            Toggle("保留弹幕颜色", isOn: preferences.$colored)
            Toggle("粗体", isOn: preferences.$bold)
            Toggle("文字阴影", isOn: preferences.$shadow)
        }
    }
    private var movement: some View {
        Section {
            Picker("显示区域", selection: preferences.$area) {
                Text("顶部四分之一").tag(0.25)
                Text("顶部一半").tag(0.5)
                Text("顶部四分之三").tag(0.75)
                Text("全屏").tag(1.0)
            }
            Picker("弹幕密度", selection: preferences.$density) {
                Text("低").tag(1); Text("中").tag(2); Text("高").tag(3)
            }
            LabeledContent("弹幕速度", value: String(format: "%.2f×", preferences.speed))
            Slider(value: preferences.$speed, in: 0.5...2, step: 0.25)
            Toggle("避让底部字幕区域", isOn: preferences.$avoidSubtitles)
        } header: { Text("布局与速度") } footer: {
            Text("速度以播放时间为基准，随视频倍速变化。底部弹幕位于所选显示区域的底部；避让开启后，预留屏幕底部空间，并非自动识别字幕位置。密度过高时仍会丢弃无空闲轨道的弹幕，避免重叠。")
        }
    }
    private var filtering: some View {
        Section {
            Toggle("滚动弹幕", isOn: preferences.$scrolling)
            Toggle("顶部固定弹幕", isOn: preferences.$top)
            Toggle("底部固定弹幕", isOn: preferences.$bottom)
            Toggle("过滤重复弹幕", isOn: preferences.$filterDuplicates)
            TextField("屏蔽关键词", text: preferences.$blockedWords, axis: .vertical)
                .lineLimit(3...6)
                .autocorrectionDisabled()
        } header: { Text("类型与过滤") } footer: {
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
