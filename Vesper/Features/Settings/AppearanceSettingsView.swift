import SwiftUI
import UIKit
import Photos
import LocalAuthentication

struct AppearanceSettingsView: View {
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    @AppStorage("appearance.accent") private var accent = "vesper"
    @State private var confirmingAccentReset = false

    var body: some View {
        SettingsPage {
            Group {
                SettingsIntroCard(title: "外观设置", symbol: "paintpalette", description: "选择深浅色外观、主题色和应用图标，打造喜欢的界面。")

                SettingsSection {
                    SettingsPicker(selection: $appearanceMode) {
                        Text("跟随系统").tag("system")
                        Text("深色").tag("dark")
                        Text("浅色").tag("light")
                    } label: { Text("主题") }
                    .pickerStyle(.menu)
                    ColorPicker(selection: Binding(
                        get: { VesperTheme.accent(accent) },
                        set: { color in
                            if let identifier = VesperTheme.accentIdentifier(for: color) {
                                accent = identifier
                            }
                        }
                    ), supportsOpacity: false) { Text("主题色") }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    Button { confirmingAccentReset = true } label: {
                        Text("重置主题色")
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                        .disabled(accent == "vesper")
                } footer: {
                    Text("主题模式控制浅色或深色外观；主题色应用于选中状态和交互强调色。")
                }
                SettingsSection {
                    AppIconChoices()
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .background(VesperTheme.background)
        .alert("重置主题色？", isPresented: $confirmingAccentReset) {
            Button("重置主题色", role: .destructive) { accent = "vesper" }
            Button("取消", role: .cancel) { }
        }
    }
}
