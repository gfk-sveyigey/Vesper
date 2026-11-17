import SwiftUI

struct PlayerGestureSettingsView: View {
    @State private var fingers = 1
    @State private var revision = 0
    @State private var confirmingReset = false
    @AppStorage("player.gesture.skipSeconds") private var skipSeconds = 15.0

    var body: some View {
        Form {
            Group {
                Section {
                    Picker("手指数", selection: $fingers) {
                        Text("单指").tag(1)
                        Text("双指").tag(2)
                        Text("三指").tag(3)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("区域控制手势仅在控制层隐藏时生效，滑动以手势开始的位置为准。控制层显示时，单指单击空白区域即可隐藏；按钮和进度条独立操作。")
                }
                ForEach(PlayerGestureRegion.allCases) { region in
                    Section(region.title) {
                        ForEach(PlayerGestureKind.allCases) { kind in
                            Picker(kind.title, selection: binding(kind, region)) {
                                ForEach(PlayerGestureAction.choices(for: kind)) { action in
                                    Text(action.title).tag(action)
                                }
                            }
                        }
                    }
                }
                Section {
                    Picker("快进快退时长", selection: $skipSeconds) {
                        ForEach([5.0, 10, 15, 30], id: \.self) { seconds in
                            Text(verbatim: String(format: VesperLocalization.string("%d 秒"), Int(seconds))).tag(seconds)
                        }
                    }
                    Button("恢复默认", role: .destructive) { confirmingReset = true }
                } footer: {
                    Text("默认单指单击切换控制层；隐藏时双击左侧快退、中间暂停或继续、右侧快进；左侧上下滑动调节亮度，右侧调节音量；任意区域左右滑动快退或快进。多指手势默认无操作。")
                }
            }
            .listRowBackground(VesperTheme.background)
        }
        .scrollContentBackground(.hidden)
        .background(VesperTheme.background)
        .navigationTitle("播放手势")
        .toolbarTitleDisplayMode(.inline)
        .alert("恢复默认手势？", isPresented: $confirmingReset) {
            Button("恢复默认", role: .destructive) { PlayerGesturePreferences.reset(); revision += 1 }
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
