import SwiftUI
import UIKit
import Photos
import LocalAuthentication

struct EmbySkipDatabasesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var databases = EmbySkipSettings.databases
    @State private var editing: EmbySkipDatabase?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            SettingsPage {

                SettingsSection {
                    ForEach($databases) { $database in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(database.name, isOn: $database.enabled)
                            Text(database.address).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text(database.format.title).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if database.isBuiltin { Text("内置").font(.caption).foregroundStyle(.secondary) }
                                else { Button("编辑") { editing = database }.buttonStyle(.borderless) }
                            }
                        }
                        .deleteDisabled(database.isBuiltin)
                    }
                    .onMove { databases.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        for index in offsets.sorted(by: >) where !databases[index].isBuiltin { databases.remove(at: index) }
                    }
                } footer: {
                    Text("从上到下查询。内置数据库只能启用、停用和调整顺序，不能修改或删除。自定义地址需使用 HTTPS。")
                }
                SettingsSection {
                    Button("添加数据库", systemImage: "plus") { adding = true }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("片头片尾数据库")
            .vesperNavigationStyle(.inline)
            .toolbarRole(.automatic)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("片头片尾数据库").font(.headline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("完成")
                        .tint(nil)
                }
            }
            .onChange(of: databases) { _, value in EmbySkipSettings.save(value) }
            .sheet(isPresented: $adding) {
                EmbySkipDatabaseEditor(database: .init(name: "", address: "https://", format: .introDB)) { databases.append($0) }
            }
            .sheet(item: $editing) { value in
                EmbySkipDatabaseEditor(database: value) { edited in
                    if let index = databases.firstIndex(where: { $0.id == edited.id }) { databases[index] = edited }
                }
            }
        }
        .presentationDetents([.custom(TabOrderDetent.self), .large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(VesperTheme.background)
    }
}

private struct EmbySkipDatabaseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var database: EmbySkipDatabase
    let save: (EmbySkipDatabase) -> Void
    private var valid: Bool {
        guard !database.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = URL(string: database.address.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
    }
    var body: some View {
        NavigationStack {
            Form {

                TextField("名称", text: $database.name)
                TextField("API 基础地址", text: $database.address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SettingsPicker("数据库格式", selection: $database.format) {
                    ForEach(EmbySkipDatabase.Format.allCases) { Text($0.title).tag($0) }
                }
                Text("IntroDB 填写 /segments 之前的地址；TheIntroDB 可填写服务根地址或含 /v4 的地址。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("数据库设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("取消")
                        .tint(nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        database.name = database.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        database.address = database.address.trimmingCharacters(in: .whitespacesAndNewlines)
                        save(database); dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("保存")
                    .tint(nil)
                    .disabled(!valid || database.isBuiltin)
                }
            }
        }
    }
}
