import SwiftUI
import UIKit

private enum SettingsRoute: Hashable {
    case tabs, gestures, appearance, logs
}

struct SettingsView: View {

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        List {
            Section("应用") {
                NavigationLink("标签设置", value: SettingsRoute.tabs)
                NavigationLink("外观设置", value: SettingsRoute.appearance)
                NavigationLink("运行日志", value: SettingsRoute.logs)
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
            Section {
                EmptyView()
            } footer: {
                Text("Vesper \(version) · Aholic")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationDestination(for: SettingsRoute.self) { route in
            switch route {
            case .tabs: TabSettingsView()
            case .gestures: GestureActionSettingsView()
            case .appearance: AppearanceSettingsView()
            case .logs: RuntimeLogsView()
            }
        }
        .navigationTitle("设置")
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct RuntimeLogsView: View {
    @ObservedObject private var store: RuntimeLogEntries
    @AppStorage("runtimeLogs.retentionDays") private var retentionDays = 7
    @AppStorage("runtimeLogs.maximumCount") private var maximumCount = 500
    @State private var loadedCount = 100
    @State private var didCopyLogs = false

    init() { store = AppLog.runtimeEntries }

    var body: some View {
        List {
            if store.storageError != nil { Text("日志文件写入失败。").foregroundStyle(.red) }
            Section("保留规则") {
                Picker("保留时间", selection: $retentionDays) {
                    Text("无限制").tag(0)
                    ForEach([1, 3, 7, 14, 30, 90], id: \.self) { days in
                        Text(String(format: NSLocalizedString("%d 天", comment: "Log retention days"), days)).tag(days)
                    }
                }
                .pickerStyle(.navigationLink)
                Picker("保留条数", selection: $maximumCount) {
                    Text("无限制").tag(0)
                    ForEach([100, 250, 500, 1_000, 2_000, 5_000], id: \.self) { count in
                        Text(String(format: NSLocalizedString("%d 条", comment: "Log retention count"), count)).tag(count)
                    }
                }
                .pickerStyle(.navigationLink)
            }
            Section(String(format: NSLocalizedString("日志（%d）", comment: "Runtime log count"), store.entries.count)) {
                if store.entries.isEmpty {
                    ContentUnavailableView("暂无运行日志", systemImage: "doc.text")
                } else {
                    ForEach(store.entries.suffix(loadedCount).reversed()) { entry in
                        Text(entry.message)
                            .font(.system(.footnote, design: .monospaced))
                            .contextMenu {
                                Button("复制日志", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = entry.message
                                }
                            }
                    }
                    if loadedCount < store.entries.count {
                        Button(String(format: NSLocalizedString("加载更早的日志（已显示 %d 条）", comment: "Load older logs"), min(loadedCount, store.entries.count))) {
                            loadedCount += 100
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("运行日志")
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("复制全部日志", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = store.exportText
                        didCopyLogs = true
                    }
                        .disabled(store.entries.isEmpty)
                    Button("清空日志", systemImage: "trash", role: .destructive) { store.clear() }
                        .disabled(store.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("日志操作")
            }
        }
        .onAppear { store.setRetention(days: retentionDays, count: maximumCount) }
        .onChange(of: retentionDays) { _, _ in store.setRetention(days: retentionDays, count: maximumCount) }
        .onChange(of: maximumCount) { _, _ in store.setRetention(days: retentionDays, count: maximumCount) }
        .alert("已复制全部日志", isPresented: $didCopyLogs) {
            Button("好", role: .cancel) { }
        }

    }
}

private struct AppearanceSettingsView: View {
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    @AppStorage("appearance.accent") private var accent = "vesper"

    var body: some View {
        Form {
            Section {
                Picker("主题", selection: $appearanceMode) {
                    Text("自动").tag("system")
                    Text("深色").tag("dark")
                    Text("浅色").tag("light")
                }
                .pickerStyle(.navigationLink)
                Picker("主题色", selection: $accent) {
                    Label { Text("薰衣草紫") } icon: { Circle().fill(VesperTheme.accent("vesper")) }.tag("vesper")
                    Label { Text("海洋蓝") } icon: { Circle().fill(VesperTheme.accent("ocean")) }.tag("ocean")
                    Label { Text("翡翠绿") } icon: { Circle().fill(VesperTheme.accent("emerald")) }.tag("emerald")
                    Label { Text("玫瑰粉") } icon: { Circle().fill(VesperTheme.accent("rose")) }.tag("rose")
                }
                .pickerStyle(.navigationLink)
                .tint(VesperTheme.accent(accent))
            } footer: {
                Text("主题模式控制浅色或深色外观；主题色应用于选中状态和交互强调色。")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("外观设置")
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}


struct TabSettingsView: View {
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("navigation.multifunctionEnabled") private var multifunctionEnabled = true

    private var sections: [AppSection] {
        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        return saved + AppSection.allCases.filter { !saved.contains($0) }
    }

    var body: some View {
        List {
            Section("标签栏") {
                Toggle("启用多功能按钮", isOn: $multifunctionEnabled)
                Text("多功能按钮仍处于试验阶段，可能出现交互或显示问题；如影响使用，请关闭此功能。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("多功能按钮手势与动作", value: SettingsRoute.gestures)
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
        .navigationTitle("标签设置")
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
            Text("分别拖动两列项目，同一行的手势与动作配对并自动保存。启用多功能按钮时使用此映射；关闭时单击搜索按钮进入搜索，长按无动作。")
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
                Text(NSLocalizedString(names[value] ?? value, comment: "Multifunction gesture or action"))
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
