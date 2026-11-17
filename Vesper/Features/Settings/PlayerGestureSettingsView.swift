import SwiftUI
import UIKit

struct PlayerGestureSettingsView: View {
    @State private var revision = 0
    @State private var confirmingReset = false
    @State private var showingRanges = false
    @State private var showingPairs = false

    var body: some View {
        let _ = revision
        SettingsPage {
            SettingsIntroCard(title: "播放手势", symbol: "hand.draw", description: "为每种手势选择区域与动作。")
            SettingsSection {
                Button { showingRanges = true } label: {
                    Label("区域范围设置", systemImage: "rectangle.split.3x1")
                }
            }
            SettingsSection {
                Button { showingPairs = true } label: {
                    Label("组合手势设置", systemImage: "arrow.up.arrow.down")
                }
            }
            ForEach(1...2, id: \.self) { fingers in
                ForEach(PlayerGesturePair.allCases.filter { pair in
                    (!pair.needsTwoFingers || fingers == 2) && PlayerGesturePreferences.pairEnabled(pair, fingers)
                }) { pair in
                    gestureSection(pair.positive, fingers: fingers, pair: pair)
                }
            }
            ForEach(1...2, id: \.self) { fingers in
                ForEach(PlayerGestureKind.allCases.filter { kind in
                    (!kind.needsTwoFingers || fingers == 2) && !isCombined(kind, fingers)
                }) { kind in
                    gestureSection(kind, fingers: fingers, pair: nil)
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .background(VesperTheme.background)
        .navigationTitle("播放手势")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("恢复默认", systemImage: "arrow.counterclockwise") { confirmingReset = true }
                    .labelStyle(.iconOnly)
            }
        }
        .alert("恢复默认手势？", isPresented: $confirmingReset) {
            Button("恢复默认", role: .destructive) { PlayerGesturePreferences.reset(); revision += 1 }
            Button("取消", role: .cancel) { }
        }
        .sheet(isPresented: $showingRanges) {
            NavigationStack { GestureRegionSettingsView() }
                .presentationDetents([.custom(GestureRegionsDetent.self)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingPairs, onDismiss: { revision += 1 }) {
            NavigationStack { GesturePairSettingsView(changed: { revision += 1 }) }
                .presentationDetents([.custom(GesturePairsDetent.self)])
                .presentationDragIndicator(.visible)
        }
    }

    private func isCombined(_ kind: PlayerGestureKind, _ fingers: Int) -> Bool {
        guard let pair = PlayerGesturePair.containing(kind) else { return false }
        return PlayerGesturePreferences.pairEnabled(pair, fingers)
    }

    private func gestureSection(_ kind: PlayerGestureKind, fingers: Int, pair: PlayerGesturePair?) -> some View {
        let count = PlayerGesturePreferences.count(for: kind, fingers: fingers)
        return SettingsSection {
            VStack(alignment: .leading, spacing: 4) {
                Text(fingers == 1 ? "单指" : "双指").font(.caption).foregroundStyle(.secondary)
                Text(pair?.title ?? kind.title).font(.headline)
            }
            .padding(.vertical, 2)
            SettingsPicker("区域划分", selection: layoutBinding(kind, fingers)) {
                Text("单区域").tag(1); Text("双区域").tag(2); Text("三区域").tag(3)
            }
            .pickerStyle(.menu)
            ForEach(PlayerGesturePreferences.regions(for: count)) { region in
                if let pair {
                    SettingsPicker(count == 1 ? "全部区域" : region.title, selection: pairActionBinding(pair, region, fingers)) {
                        ForEach(PlayerGesturePairAction.allCases) { action in Text(action.title).tag(action) }
                    }
                    .pickerStyle(.menu)
                } else {
                    SettingsPicker(count == 1 ? "全部区域" : region.title, selection: actionBinding(kind, region, fingers)) {
                        ForEach(PlayerGestureAction.allCases) { action in Text(action.title).tag(action) }
                    }
                    .pickerStyle(.menu)
                }
            }
        }
    }

    private func layoutBinding(_ kind: PlayerGestureKind, _ fingers: Int) -> Binding<Int> {
        Binding { PlayerGesturePreferences.count(for: kind, fingers: fingers) } set: { value in
            UserDefaults.standard.set(value, forKey: PlayerGesturePreferences.layoutKey(kind, fingers))
            revision += 1
        }
    }
    private func actionBinding(_ kind: PlayerGestureKind, _ region: PlayerGestureRegion, _ fingers: Int) -> Binding<PlayerGestureAction> {
        Binding { PlayerGesturePreferences.action(kind, region, fingers) } set: { value in
            UserDefaults.standard.set(value.rawValue, forKey: PlayerGesturePreferences.key(kind, region, fingers))
            revision += 1
        }
    }
    private func pairActionBinding(_ pair: PlayerGesturePair, _ region: PlayerGestureRegion, _ fingers: Int) -> Binding<PlayerGesturePairAction> {
        Binding { PlayerGesturePreferences.pairAction(pair, region, fingers) } set: { value in
            UserDefaults.standard.set(value.rawValue, forKey: PlayerGesturePreferences.pairKey(pair, region, fingers))
            revision += 1
        }
    }
}

private struct GesturePairSettingsView: View {
    let changed: () -> Void
    @State private var revision = 0
    var body: some View {
        SettingsPage {
            ForEach(1...2, id: \.self) { fingers in
                SettingsSection {
                    Text(fingers == 1 ? "单指" : "双指").font(.headline)
                    ForEach(PlayerGesturePair.allCases.filter { !($0.needsTwoFingers && fingers == 1) }) { pair in
                        Toggle(pair.title, isOn: Binding {
                            let _ = revision
                            return PlayerGesturePreferences.pairEnabled(pair, fingers)
                        } set: { value in
                            UserDefaults.standard.set(value, forKey: "player.gesture.paired.\(fingers).\(pair.rawValue)")
                            revision += 1
                            changed()
                        })
                    }
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden).background(VesperTheme.background)
        .navigationTitle("组合手势设置").toolbarTitleDisplayMode(.inline)
    }
}

private struct GestureRegionSettingsView: View {
    @AppStorage("player.gesture.split2") private var split2 = 0.5
    @AppStorage("player.gesture.split3.first") private var splitFirst = 1.0 / 3
    @AppStorage("player.gesture.split3.second") private var splitSecond = 2.0 / 3

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 1) {
                    preview([0, split2, 1])
                    preview([0, splitFirst, splitSecond, 1])
                }
                .aspectRatio(3.5, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("区域划分预览")
                VStack(alignment: .leading, spacing: 12) {
                    Text("双区域").font(.headline)
                    Text(verbatim: "\(Int((split2 * 100).rounded()))% / \(Int(((1 - split2) * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    GestureRangeSlider(lower: $split2, upper: .constant(1), singleHandle: true)
                }
                .padding(16).settingsCardBackground()
                VStack(alignment: .leading, spacing: 12) {
                    Text("三区域").font(.headline)
                    Text(verbatim: "\(Int((splitFirst * 100).rounded()))% / \(Int(((splitSecond - splitFirst) * 100).rounded()))% / \(Int(((1 - splitSecond) * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    GestureRangeSlider(lower: $splitFirst, upper: $splitSecond)
                }
                .padding(16).settingsCardBackground()
            }
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .background(VesperTheme.background)
        .navigationTitle("区域范围设置").toolbarTitleDisplayMode(.inline)
    }

    private func preview(_ edges: [Double]) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(0..<(edges.count - 1), id: \.self) { index in
                    let fraction: Double = edges[index + 1] - edges[index]
                    let percentage: Int = Int((fraction * 100).rounded())
                    let width: CGFloat = max(0, geometry.size.width * CGFloat(fraction) - 1)
                    Text(verbatim: "\(percentage)%")
                        .font(Font.title3.weight(.semibold).monospacedDigit())
                        .frame(width: width, height: geometry.size.height)
                        .background(Color.accentColor.opacity(0.18))
                }
            }
        }
    }
}

/// Both variants use UISlider's native track and thumb appearance. The two
/// handles share the same bounds, and hit-testing selects the nearest handle.
private struct GestureRangeSlider: UIViewRepresentable {
    @Binding var lower: Double
    @Binding var upper: Double
    var singleHandle = false
    func makeUIView(context: Context) -> RangeView { RangeView() }
    func updateUIView(_ view: RangeView, context: Context) {
        view.single = singleHandle
        view.lower.setValue(Float(lower), animated: false)
        view.upper.setValue(Float(upper), animated: false)
        view.changed = { first, second in lower = first; if !singleHandle { upper = second } }
        view.applyStyle()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RangeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: 44)
    }
    final class RangeView: UIView {
        let lower = UISlider()
        let upper = UISlider()
        var single = false
        var changed: ((Double, Double) -> Void)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(upper); addSubview(lower)
            for slider in [lower, upper] {
                slider.minimumValue = 0; slider.maximumValue = 1
                slider.addTarget(self, action: #selector(valueChanged(_:)), for: .valueChanged)
            }
            lower.accessibilityLabel = VesperLocalization.string("左侧区域边界")
            upper.accessibilityLabel = VesperLocalization.string("右侧区域边界")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); lower.frame = bounds; upper.frame = bounds }
        func applyStyle() {
            upper.isHidden = single
            upper.minimumTrackTintColor = tintColor
            upper.maximumTrackTintColor = .tertiarySystemFill
            lower.minimumTrackTintColor = single ? tintColor : .tertiarySystemFill
            lower.maximumTrackTintColor = single ? .tertiarySystemFill : .clear
            lower.accessibilityValue = "\(Int((lower.value * 100).rounded()))%"
            upper.accessibilityValue = "\(Int((upper.value * 100).rounded()))%"
        }
        @objc private func valueChanged(_ sender: UISlider) {
            if sender === lower { lower.value = min(single ? 0.85 : upper.value - 0.15, max(0.15, lower.value)) }
            else { upper.value = min(0.85, max(lower.value + 0.15, upper.value)) }
            applyStyle()
            changed?(Double(lower.value), Double(upper.value))
        }
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard self.point(inside: point, with: event) else { return nil }
            if single { return lower }
            let first = lower.thumbRect(forBounds: lower.bounds, trackRect: lower.trackRect(forBounds: lower.bounds), value: lower.value).midX
            let second = upper.thumbRect(forBounds: upper.bounds, trackRect: upper.trackRect(forBounds: upper.bounds), value: upper.value).midX
            return abs(point.x - first) <= abs(point.x - second) ? lower : upper
        }
    }
}

private struct GestureRegionsDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(context.maxDetentValue, context.dynamicTypeSize.isAccessibilitySize ? 680 : 470)
    }
}

private struct GesturePairsDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(context.maxDetentValue, context.dynamicTypeSize.isAccessibilitySize ? 700 : 500)
    }
}
