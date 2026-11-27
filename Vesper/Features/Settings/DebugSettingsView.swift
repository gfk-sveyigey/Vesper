import SwiftUI
import UIKit

struct DebugSettingsSection<Rows: View, Footer: View>: View {
    let title: LocalizedStringKey
    let rows: Rows
    let footer: Footer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    init(title: LocalizedStringKey, @ViewBuilder rows: () -> Rows, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.rows = rows()
        self.footer = footer()
    }

    var body: some View {
        SettingsSection {
            Button {
                withAnimation(reduceMotion ? nil : .default) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(title).fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            if isExpanded { rows }
        } footer: {
            if isExpanded { footer }
        }
    }
}

extension DebugSettingsSection where Footer == EmptyView {
    init(title: LocalizedStringKey, @ViewBuilder rows: () -> Rows) {
        self.init(title: title, rows: rows, footer: { EmptyView() })
    }
}

struct DebugSettingsView: View {
    @AppStorage("debug.mediaHeader.lightTint") private var lightTint = "#FFFFFF"
    @AppStorage("debug.mediaHeader.darkTint") private var darkTint = "#000000"
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @AppStorage(EmbyUserAgentPolicy.enabledKey) private var enabled = false
    @AppStorage(EmbyUserAgentPolicy.nameKey) private var clientName = ""
    @AppStorage(EmbyUserAgentPolicy.versionKey) private var clientVersion = ""
    @AppStorage(PlaybackDiagnostics.controlTopPortraitSpacingKey) private var topPortraitSpacing = PlaybackDiagnostics.defaultControlEdgeSpacing
    @AppStorage(PlaybackDiagnostics.controlTopLandscapeSpacingKey) private var topLandscapeSpacing = PlaybackDiagnostics.defaultControlEdgeSpacing
    @AppStorage(PlaybackDiagnostics.controlBottomPortraitSpacingKey) private var bottomPortraitSpacing = PlaybackDiagnostics.defaultControlEdgeSpacing
    @AppStorage(PlaybackDiagnostics.controlBottomLandscapeSpacingKey) private var bottomLandscapeSpacing = PlaybackDiagnostics.defaultControlEdgeSpacing
    @AppStorage(PlaybackDiagnostics.controlScrimOpacityKey) private var controlScrimOpacity = PlaybackDiagnostics.defaultControlScrimOpacity
    @AppStorage(PlaybackDiagnostics.controlGlassClearKey) private var controlGlassClear = false

    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "调试功能", symbol: "ladybug", description: "调试 Emby 客户端标识、界面布局与播放器控制区。")
            DebugSettingsSection(title: "客户端模拟") {
                Toggle("启用客户端模拟", isOn: $enabled)
                if enabled {
                    TextField("客户端名称", text: $clientName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("客户端版本", text: $clientVersion)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                LabeledContent("当前标识") {
                    Text(verbatim: "\(EmbyUserAgentPolicy.clientName)/\(EmbyUserAgentPolicy.clientVersion)")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("客户端名称和版本会同时用于 User-Agent 及 Emby Authorization 请求头。留空或关闭时使用 Vesper 默认值。")
            }
            DebugSettingsSection(title: "界面设计") {
                controlEdgeSpacingStepper("竖屏顶部间距", value: $topPortraitSpacing)
                controlEdgeSpacingStepper("横屏顶部间距", value: $topLandscapeSpacing)
                controlEdgeSpacingStepper("竖屏底部间距", value: $bottomPortraitSpacing)
                controlEdgeSpacingStepper("横屏底部间距", value: $bottomLandscapeSpacing)
                Stepper(value: $controlScrimOpacity, in: PlaybackDiagnostics.controlScrimOpacityRange) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("黑色遮罩强度")
                        Text(Double(controlScrimOpacity) / 100, format: .percent)
                            .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                SettingsPicker("液态玻璃材质", selection: $controlGlassClear) {
                    Text("标准").tag(false)
                    Text("通透").tag(true)
                }
                ForEach(Self.interfaceMetrics, id: \.self) { metric in
                    layoutStepper(metric)
                }
                Button("恢复默认值", systemImage: "arrow.counterclockwise") {
                    layout.reset(Self.interfaceMetrics)
                    topPortraitSpacing = PlaybackDiagnostics.defaultControlEdgeSpacing
                    topLandscapeSpacing = PlaybackDiagnostics.defaultControlEdgeSpacing
                    bottomPortraitSpacing = PlaybackDiagnostics.defaultControlEdgeSpacing
                    bottomLandscapeSpacing = PlaybackDiagnostics.defaultControlEdgeSpacing
                    controlScrimOpacity = PlaybackDiagnostics.defaultControlScrimOpacity
                    controlGlassClear = false
                }
            }
            DebugSettingsSection(title: "媒体页导航栏") {
                ForEach(Self.headerMetrics, id: \.self) { metric in
                    if metric == .mediaSnapConflict {
                        SettingsPicker(metric.label, selection: Binding(
                            get: { layout[metric] }, set: { layout[metric] = $0 }
                        )) {
                            Text("根据滚动方向").tag(0)
                            Text("根据距离").tag(1)
                        }
                    } else if metric == .mediaEdgeCurve || metric == .mediaEdgeHeightCurve || metric == .mediaContentOpacityCurve || metric == .mediaContentBlurCurve || metric == .mediaSnapCurve {
                        SettingsPicker(metric.label, selection: Binding(
                            get: { layout[metric] }, set: { layout[metric] = $0 }
                        )) {
                            Text("线性").tag(0)
                            Text("缓入缓出").tag(1)
                            Text("缓入").tag(2)
                            Text("缓出").tag(3)
                            Text("平滑阶梯").tag(4)
                        }
                    } else {
                        layoutStepper(metric)
                    }
                }
                Button("恢复默认值", systemImage: "arrow.counterclockwise") {
                    layout.reset(Self.headerMetrics)
                }
            }
            DebugSettingsSection(title: "轮播图底部模糊") {
                ForEach(Self.carouselBlurMetrics, id: \.self) { metric in
                    layoutStepper(metric)
                }
                Button("恢复默认值", systemImage: "arrow.counterclockwise") {
                    layout.reset(Self.carouselBlurMetrics)
                }
            }
        }
    }

    private static let headerMetrics: [MediaLayoutSettings.Metric] = [
        .mediaHeaderHeight, .mediaGlassStrength, .mediaGlassTint,
        .mediaGlassBorderWidth, .mediaGlassBorderBlur, .mediaGlassBorderOpacity, .mediaContentBlur,
        .mediaContentBlurCurve, .mediaContentOpacityCurve,
        .mediaSnapThreshold, .mediaSnapCollapsedThreshold, .mediaSnapConflict, .mediaSnapDuration, .mediaSnapCurve,
        .mediaEdgeTopStrength, .mediaEdgeTopMaxStrength, .mediaEdgeHeightCurve,
        .mediaEdgeBottomStrength, .mediaEdgeTint, .mediaEdgeCurve
    ]

    private static let carouselBlurMetrics: [MediaLayoutSettings.Metric] = [
        .carouselBlurHeight, .carouselBlurFadeHeight, .carouselBlurStrength, .carouselBlurTint
    ]

    private static let interfaceMetrics = MediaLayoutSettings.Metric.allCases.filter {
        !headerMetrics.contains($0) && !carouselBlurMetrics.contains($0)
    }

    private func controlEdgeSpacingStepper(_ title: LocalizedStringKey, value: Binding<Int>) -> some View {
        Stepper(value: value, in: PlaybackDiagnostics.controlEdgeSpacingRange) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text("\(value.wrappedValue) pt")
                    .font(.footnote).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func layoutStepper(_ metric: MediaLayoutSettings.Metric) -> some View {
        let value = layout[metric]
        let displayValue: Text
        if metric == .thumbnailHeight && value == 0 {
            displayValue = Text("自动")
        } else if metric == .mediaGlassBorderWidth {
            let width = Double(layout.mediaGlassBorderWidth)
            displayValue = Text("\(width, format: .number.precision(.fractionLength(2))) pt")
        } else if metric == .mediaSnapDuration {
            displayValue = Text("\(value) ms")
        } else if metric.usesPercent || metric == .mediaSnapThreshold || metric == .mediaSnapCollapsedThreshold {
            displayValue = Text(Double(value) / 100, format: .percent)
        } else {
            displayValue = Text("\(value) pt")
        }
        return Stepper(value: Binding(get: { layout[metric] }, set: { layout[metric] = $0 }),
                       in: metric.range) {
            VStack(alignment: .leading, spacing: 3) {
                Text(metric.label)
                displayValue.font(.footnote).monospacedDigit().foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityLabel(Text(metric.label))
        .accessibilityValue(displayValue)
    }
}
