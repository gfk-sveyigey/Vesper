import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section("应用") {
                NavigationLink("标签显示与顺序") { TabSettingsView() }
                NavigationLink("多功能按钮手势与动作") { GestureActionSettingsView() }
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


struct TabSettingsView: View {
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("navigation.allowsHidingTabBar") private var allowsHidingTabBar = true

    private var sections: [AppSection] {
        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        return saved + AppSection.allCases.filter { !saved.contains($0) }
    }

    var body: some View {
        List {
            Section("标签栏") {
                Toggle("允许隐藏标签栏", isOn: $allowsHidingTabBar)
            }
            Section {
                ForEach(sections) { section in
                    Toggle(isOn: Binding(
                        get: { section == .settings || !hidden.split(separator: ",").contains(Substring(section.rawValue)) },
                        set: { visible in
                            guard section != .settings else { return }
                            var values = Set(hidden.split(separator: ",").map(String.init))
                            if visible { values.remove(section.rawValue) } else { values.insert(section.rawValue) }
                            hidden = values.sorted().joined(separator: ",")
                        }
                    )) { Label(section.title, systemImage: section.symbol) }
                    .disabled(section == .settings)
                }
                .onMove { offsets, destination in
                    var values = sections
                    values.move(fromOffsets: offsets, toOffset: destination)
                    order = values.map(\.rawValue).joined(separator: ",")
                }
            } footer: {
                Text("拖动调整顺序。关闭只隐藏入口，不清除页面数据。多功能入口始终保留，设置标签不允许隐藏，但可调整顺序。")
            }
            Button("恢复默认") {
                order = "media,sources,history,settings"
                hidden = ""
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("标签显示与顺序")
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}


private struct GestureActionSettingsView: View {
    @AppStorage("navigation.gestureOrder") private var gestureOrder = "tap,longPress"
    @AppStorage("navigation.actionOrder") private var actionOrder = "tabs,search"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("手势").frame(maxWidth: .infinity)
                Text("动作").frame(maxWidth: .infinity)
            }
            .font(.headline)
            .padding()
            HStack(spacing: 0) {
                column($gestureOrder, names: ["tap": "单击", "longPress": "长按"])
                column($actionOrder, names: ["tabs": "展开标签栏", "search": "进入搜索"])
            }
            Text("分别拖动两列项目，同一行的手势与动作配对并自动保存。关闭允许隐藏标签栏时，展开动作无效；进入搜索仍可使用。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("手势与动作")
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private func column(_ storage: Binding<String>, names: [String: String]) -> some View {
        let values = storage.wrappedValue.split(separator: ",").map(String.init)
        return List {
            ForEach(values, id: \.self) { value in
                Text(names[value] ?? value)
                    .frame(minHeight: 44)
                    .accessibilityHint("拖动调整配对顺序")
            }
            .onMove { offsets, destination in
                var updated = values
                updated.move(fromOffsets: offsets, toOffset: destination)
                storage.wrappedValue = updated.joined(separator: ",")
            }
        }
        .listStyle(.plain)
    }
}
