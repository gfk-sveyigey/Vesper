import SwiftUI

struct SourcesView: View {
    @EnvironmentObject private var library: SourceLibrary
    @State private var isAdding = false

    var body: some View {
        List {
            Section {
                VesperLargeTitle("来源")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if library.sources.isEmpty {
                ContentUnavailableView("未配置来源", systemImage: "externaldrive")
            }
            Section {
                ForEach(library.sources) { source in
                    VStack(alignment: .leading, spacing: 10) {
                        Button { library.select(source.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: source.name).foregroundStyle(.primary)
                                    Text("演示来源").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if source.id == library.selectedID {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(source.id == library.selectedID ? .isSelected : [])
                        Picker("来源状态", selection: Binding(
                            get: { source.behavior },
                            set: { library.configure(source.id, behavior: $0) }
                        )) {
                            ForEach(DemoSourceBehavior.allCases) { behavior in
                                Text(LocalizedStringKey(behavior.titleKey)).tag(behavior)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { library.remove(source.id) }
                    }
                }
            } footer: {
                Text("演示来源仅用于验证来源切换和页面状态，不包含真实媒体。")
            }
            Button("添加演示来源", systemImage: "plus") { isAdding = true }
            if library.storageFailed { Text("来源设置保存失败").foregroundStyle(.red) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .vesperImmersiveTitle("来源")
        .sheet(isPresented: $isAdding) {
            AddDemoSourceView { name, behavior in library.addDemo(name: name, behavior: behavior) }
        }
    }
}

private struct AddDemoSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var behavior = DemoSourceBehavior.content
    let save: (String, DemoSourceBehavior) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("来源名称", text: $name)
                Picker("来源状态", selection: $behavior) {
                    ForEach(DemoSourceBehavior.allCases) { item in
                        Text(LocalizedStringKey(item.titleKey)).tag(item)
                    }
                }
                .pickerStyle(.menu)
                Text("演示来源仅用于验证来源切换和页面状态，不包含真实媒体。")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("添加演示来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { save(name, behavior); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
