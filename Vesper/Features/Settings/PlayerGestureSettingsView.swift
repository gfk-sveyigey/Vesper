import SwiftUI

struct PlayerGestureSettingsView: View {
    @State private var fingers = 1
    @State private var revision = 0
    @State private var confirmingReset = false
    @AppStorage("player.gesture.regionCount") private var regionCount = 3
    @AppStorage("player.gesture.split2") private var split2 = 0.5
    @AppStorage("player.gesture.split3.first") private var splitFirst = 1.0 / 3
    @AppStorage("player.gesture.split3.second") private var splitSecond = 2.0 / 3

    var body: some View {
        Form {
            Group {
                SettingsIntroCard(title: "播放手势", symbol: "hand.draw", description: "自定义区域与单指、双指操作。")
                Section {
                    Picker("手指数", selection: $fingers) {
                        Text("单指").tag(1)
                        Text("双指").tag(2)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("手势仅在控制层隐藏时生效，以起始区域为准。单击空白区域可隐藏控制层。")
                }
                Section {
                    Picker("区域数量", selection: $regionCount) {
                        Text("单区域").tag(1); Text("双区域").tag(2); Text("三区域").tag(3)
                    }
                    if regionCount == 2 {
                        Text(verbatim: "\(Int(split2 * 100))% / \(100 - Int(split2 * 100))%")
                        Slider(value: $split2, in: 0.15...0.85, step: 0.01).accessibilityLabel("左侧区域比例")
                    } else if regionCount == 3 {
                        Text(verbatim: "\(Int(splitFirst * 100))% / \(Int((splitSecond - splitFirst) * 100))% / \(100 - Int(splitSecond * 100))%")
                        Slider(value: $splitFirst, in: 0.15...max(0.15, splitSecond - 0.15), step: 0.01).accessibilityLabel("左侧区域比例")
                        Slider(value: $splitSecond, in: min(0.85, splitFirst + 0.15)...0.85, step: 0.01).accessibilityLabel("右侧区域边界")
                    }
                }
                ForEach(PlayerGesturePreferences.regions) { region in
                    Section {
                        ForEach(PlayerGestureKind.allCases.filter { fingers == 2 || !$0.needsTwoFingers }) { kind in
                            Picker(selection: binding(kind, region)) {
                                ForEach(PlayerGestureAction.choices(for: kind)) { action in
                                    Text(action.title).tag(action)
                                }
                            } label: {
                                HStack { Text(region.title); Spacer(); Text(kind.title).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Section {
                    Button("恢复默认", role: .destructive) { confirmingReset = true }
                } footer: {
                    Text("快进快退使用播放设置中的时长。每种手势均可选择任意动作。")
                }
            }
            .listRowBackground(VesperTheme.background)
        }
        .listSectionSpacing(28)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(VesperTheme.background)
        .navigationTitle("播放手势")
        .toolbarTitleDisplayMode(.inline)
        .alert("恢复默认手势？", isPresented: $confirmingReset) {
            Button("恢复默认", role: .destructive) { PlayerGesturePreferences.reset(); regionCount = 3; split2 = 0.5; splitFirst = 1.0 / 3; splitSecond = 2.0 / 3; revision += 1 }
            Button("取消", role: .cancel) { }
        }
    }
    private func binding(_ kind: PlayerGestureKind, _ region: PlayerGestureRegion) -> Binding<PlayerGestureAction> {
        let _ = revision
        return Binding {
            PlayerGesturePreferences.action(kind, region, fingers)
        } set: { action in
            UserDefaults.standard.set(action.rawValue, forKey: PlayerGesturePreferences.key(kind, region, fingers))
            revision += 1
        }
    }
}
