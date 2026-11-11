import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section("应用") {
                NavigationLink("标签显示与顺序") { TabSettingsView() }
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

    private var sections: [AppSection] {
        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        return saved + AppSection.allCases.filter { !saved.contains($0) }
    }

    var body: some View {
        List {
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

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label(query.isEmpty ? "搜索媒体" : "暂无可搜索内容", systemImage: "magnifyingglass")
            } description: {
                Text("搜索范围为当前媒体来源。真实媒体来源尚未接入，暂时无法返回结果。")
            }
            .searchable(text: $query, prompt: "搜索当前来源")
            .navigationTitle("搜索")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }

            }
        }
    }
}
