import SwiftUI

struct PlayerGestureSettingsView: View {
    @State private var revision = 0
    @State private var confirmingReset = false
    @State private var showingRanges = false
    @State private var showingPairs = false

    var body: some View {
        let _ = revision
        Form {
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
        .listSectionSpacing(20)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
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
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingPairs, onDismiss: { revision += 1 }) {
            NavigationStack { GesturePairSettingsView() }
                .presentationDetents([.medium, .large])
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
            Picker("区域划分", selection: layoutBinding(kind, fingers)) {
                Text("单区域").tag(1); Text("双区域").tag(2); Text("三区域").tag(3)
            }
            .pickerStyle(.menu)
            ForEach(PlayerGesturePreferences.regions(for: count)) { region in
                if let pair {
                    Picker(count == 1 ? "全部区域" : region.title, selection: pairActionBinding(pair, region, fingers)) {
                        ForEach(PlayerGesturePairAction.allCases) { action in Text(action.title).tag(action) }
                    }
                    .pickerStyle(.menu)
                } else {
                    Picker(count == 1 ? "全部区域" : region.title, selection: actionBinding(kind, region, fingers)) {
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
    @Environment(\.dismiss) private var dismiss
    @State private var revision = 0
    var body: some View {
        Form {
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
                        })
                    }
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden).background(VesperTheme.background)
        .navigationTitle("组合手势设置").toolbarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) } }
    }
}

private struct GestureRegionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
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
                .aspectRatio(16.0 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("区域划分预览")
                VStack(alignment: .leading, spacing: 12) {
                    Text("双区域").font(.headline)
                    Text(verbatim: "\(Int((split2 * 100).rounded()))% / \(Int(((1 - split2) * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Slider(value: $split2, in: 0.15...0.85, step: 0.01).accessibilityLabel("左侧区域比例")
                }
                .padding(16).settingsCardBorder()
                VStack(alignment: .leading, spacing: 12) {
                    Text("三区域").font(.headline)
                    Text(verbatim: "\(Int((splitFirst * 100).rounded()))% / \(Int(((splitSecond - splitFirst) * 100).rounded()))% / \(Int(((1 - splitSecond) * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    GestureRangeSlider(lower: $splitFirst, upper: $splitSecond)
                }
                .padding(16).settingsCardBorder()
            }
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .background(VesperTheme.background)
        .navigationTitle("区域范围设置").toolbarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly) } }
    }

    private func preview(_ edges: [Double]) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(0..<(edges.count - 1), id: \.self) { index in
                    Text(verbatim: "\(Int(((edges[index + 1] - edges[index]) * 100).rounded()))%")
                        .font(.caption.monospacedDigit().bold())
                        .frame(width: max(0, geometry.size.width * (edges[index + 1] - edges[index]) - 1), height: geometry.size.height)
                        .background(index.isMultiple(of: 2) ? Color.accentColor.opacity(0.25) : Color.accentColor.opacity(0.45))
                }
            }
        }
    }
}

/// Two handles share one track; neither handle can cross the other or erase a region.
private struct GestureRangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    @State private var lowerStart: Double?
    @State private var upperStart: Double?
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 28)
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.2)).frame(height: 4)
                Capsule().fill(.tint).frame(width: width * (upper - lower), height: 4).offset(x: 14 + width * lower)
                handle(value: $lower, start: $lowerStart, width: width, limits: 0.15...max(0.15, upper - 0.15), title: "左侧区域边界")
                handle(value: $upper, start: $upperStart, width: width, limits: min(0.85, lower + 0.15)...0.85, title: "右侧区域边界")
            }
            .frame(height: 44)
        }
        .frame(height: 44)
    }
    private func handle(value: Binding<Double>, start: Binding<Double?>, width: CGFloat, limits: ClosedRange<Double>, title: LocalizedStringKey) -> some View {
        Circle().fill(.white).shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .frame(width: 28, height: 28).frame(width: 44, height: 44)
            .offset(x: width * value.wrappedValue - 8)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                if start.wrappedValue == nil { start.wrappedValue = value.wrappedValue }
                value.wrappedValue = min(limits.upperBound, max(limits.lowerBound, (start.wrappedValue ?? value.wrappedValue) + drag.translation.width / width))
            }.onEnded { _ in start.wrappedValue = nil })
            .accessibilityElement().accessibilityLabel(title)
            .accessibilityValue(Text(verbatim: "\(Int(value.wrappedValue * 100))%"))
            .accessibilityAdjustableAction { direction in
                value.wrappedValue = min(limits.upperBound, max(limits.lowerBound, value.wrappedValue + (direction == .increment ? 0.01 : -0.01)))
            }
    }
}
