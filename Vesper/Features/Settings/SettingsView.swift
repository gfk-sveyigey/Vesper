import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section("应用") {
                NavigationLink("外观") { AppearanceSettingsView() }
            }
            Section {
                LabeledContent("播放器偏好", value: "尚未接入")
                LabeledContent("IMDb", value: "尚未连接")
                LabeledContent("Trakt", value: "尚未连接")
            } header: {
                Text("后续功能")
            } footer: {
                Text("播放器和外部服务将在对应阶段接入，当前不会提供无效的开关或连接按钮。")
            }
            Section("关于") {
                LabeledContent("Vesper", value: "导航原型")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("设置")
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct AppearanceSettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("外观", value: "跟随系统")
                Label("Vesper Violet", systemImage: "circle.fill")
                    .foregroundStyle(Color("VesperAccent"))
            } footer: {
                Text("当前原型自动使用系统的浅色或深色外观。")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("外观")
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}
