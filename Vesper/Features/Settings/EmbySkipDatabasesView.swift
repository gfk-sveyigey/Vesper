import SwiftUI
import UIKit
import Photos
import LocalAuthentication

struct EmbySkipDatabasesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var databases = EmbySkipSettings.databases
    @State private var editing: EmbySkipDatabase?
    @State private var deleting: EmbySkipDatabase?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            SettingsPage {

                SettingsSection("查询顺序") {
                    ForEach($databases) { $database in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(verbatim: database.name)
                                        .font(.headline)
                                    Text(verbatim: database.address)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Toggle("", isOn: $database.enabled)
                                    .labelsHidden()
                                    .accessibilityLabel(Text(verbatim: database.name))
                            }

                            HStack(spacing: 12) {
                                Text(database.format.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if database.isBuiltin {
                                    Text("内置")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    editing = database
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .accessibilityLabel("编辑数据库")
                                .disabled(database.isBuiltin)

                                Button {
                                    move(database.id, by: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .accessibilityLabel("上移数据库")
                                .disabled(databases.first?.id == database.id)

                                Button {
                                    move(database.id, by: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .accessibilityLabel("下移数据库")
                                .disabled(databases.last?.id == database.id)

                                Button(role: .destructive) {
                                    deleting = database
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel("删除数据库")
                                .disabled(database.isBuiltin)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 6)
                    }
                } footer: {
                    Text("从上到下查询。内置数据库可启用、停用和调整顺序；自定义数据库支持编辑和删除，地址需使用 HTTPS。")
                }
                SettingsSection {
                    Button("添加数据库", systemImage: "plus") { adding = true }
                }
            }
            .navigationTitle("片头片尾数据库")
            .vesperNavigationStyle(.inline)
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
            .alert(item: $deleting) { database in
                Alert(
                    title: Text("删除数据库？"),
                    message: Text(verbatim: database.name),
                    primaryButton: .destructive(Text("删除")) {
                        databases.removeAll { $0.id == database.id }
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
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

    private func move(_ id: String, by offset: Int) {
        guard let index = databases.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard databases.indices.contains(destination) else { return }
        databases.swapAt(index, destination)
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
