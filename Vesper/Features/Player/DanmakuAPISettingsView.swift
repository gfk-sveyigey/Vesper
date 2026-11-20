import SwiftUI

@MainActor
final class DanmakuAPISources: ObservableObject {
    static let shared = DanmakuAPISources()
    @Published var sources: [DanmakuAPISource] {
        didSet {
            if let data = try? JSONEncoder().encode(sources) {
                UserDefaults.standard.set(data, forKey: "danmaku.api.sources")
            }
        }
    }
    private init() {
        sources = UserDefaults.standard.data(forKey: "danmaku.api.sources")
            .flatMap { try? JSONDecoder().decode([DanmakuAPISource].self, from: $0) } ?? []
    }
}

struct DanmakuAPISettingsView: View {
    @ObservedObject private var store = DanmakuAPISources.shared
    @State private var name = ""
    @State private var address = ""
    @State private var error: String?
    var body: some View {
        Form {
            Section("已添加的 API") {
                ForEach($store.sources) { $source in
                    VStack(alignment: .leading) {
                        Toggle(source.name, isOn: $source.enabled)
                        NavigationLink("编辑 API") { DanmakuAPIEditor(source: $source) }
                        // Do not display path tokens in the source list.
                        Text(URL(string: source.address)?.host ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { store.sources.remove(atOffsets: $0) }
            }
            Section {
                TextField("名称", text: $name)
                TextField("HTTPS API 基础地址", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("添加 API") { add() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.isEmpty)
                if let error { Text(error).foregroundStyle(.red) }
            } header: { Text("自定义弹幕 API") } footer: {
                Text("支持弹弹play兼容格式（包括 LogVar / danmu_api）。地址可包含反向代理路径或访问令牌前缀，也可填写到 /api/v2。地址仅保存在本机。搜索时会向所选服务发送搜索词，不会附带 Emby 凭据。")
            }
        }
        .navigationTitle("弹幕 API")
    }
    private func add() {
        let source = DanmakuAPISource(name: name.trimmingCharacters(in: .whitespacesAndNewlines), address: address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        do {
            _ = try source.endpoint(["search", "anime"])
            store.sources.append(source)
            name = ""; address = ""; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct DanmakuAPISearchView: View {
    @ObservedObject var document: PlayerDanmaku
    @ObservedObject private var store = DanmakuAPISources.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: UUID?
    @State private var keyword = ""
    @State private var works: [DanmakuAPIItem] = []
    @State private var episodes: [DanmakuAPIItem] = []
    @State private var workTitle: String?
    @State private var status = ""
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    private var sources: [DanmakuAPISource] { store.sources.filter(\.enabled) }
    private var source: DanmakuAPISource? { sources.first { $0.id == sourceID } }

    var body: some View {
        List {
            Section {
                NavigationLink("管理弹幕 API") { DanmakuAPISettingsView() }
                Picker("弹幕 API", selection: $sourceID) {
                    Text("请选择").tag(Optional<UUID>.none)
                    ForEach(sources) { item in Text(item.name).tag(Optional(item.id)) }
                }.disabled(busy)
                TextField("作品名称", text: $keyword).onSubmit { search() }
                Button("搜索作品", action: search)
                    .disabled(busy || source == nil || keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if busy { ProgressView() }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            } footer: { Text("请选择与当前视频对应的来源和集数，加载成功后替换当前弹幕。") }
            if let workTitle {
                Section(workTitle) {
                    Button("返回作品列表") { episodes = []; self.workTitle = nil }
                    ForEach(episodes) { episode in
                        Button(episode.title) { load(episode) }.disabled(busy)
                    }
                }
            } else {
                Section("搜索结果") {
                    ForEach(works) { work in
                        Button(work.title) { select(work) }.disabled(busy)
                    }
                }
            }
        }
        .navigationTitle("在线弹幕")
        .onAppear { if sourceID == nil { sourceID = sources.first?.id } }
        .onChange(of: sourceID) { _, _ in works = []; episodes = []; workTitle = nil; status = "" }
        .onDisappear { operation?.cancel() }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        operation?.cancel(); busy = true; status = ""
        operation = Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
    private func search() {
        guard !busy, let source else { return }
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        works = []; episodes = []; workTitle = nil
        perform {
            let result = try await DanmakuAPI.search(source: source, keyword: query)
            try Task.checkCancellation()
            works = result
            if result.isEmpty { status = "未找到匹配的作品。" }
        }
    }
    private func select(_ work: DanmakuAPIItem) {
        guard let source else { return }
        perform {
            let result = try await DanmakuAPI.episodes(source: source, id: work.id)
            try Task.checkCancellation()
            episodes = result; workTitle = work.title
            if result.isEmpty { status = "该作品暂无剧集。" }
        }
    }
    private func load(_ episode: DanmakuAPIItem) {
        guard let source else { return }
        perform {
            let result = try await DanmakuAPI.comments(source: source, id: episode.id)
            try Task.checkCancellation()
            document.comments = result
            document.filename = "\(source.name) · \(episode.title)"
            document.offset = 0
            dismiss()
        }
    }
}


private struct DanmakuAPIEditor: View {
    @Binding var source: DanmakuAPISource
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var error: String?
    var body: some View {
        Form {
            TextField("名称", text: $name)
            TextField("HTTPS API 基础地址", text: $address)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button("保存") {
                var edited = source
                edited.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                edited.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
                do {
                    _ = try edited.endpoint([])
                    source = edited
                    dismiss()
                } catch { self.error = error.localizedDescription }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("编辑弹幕 API")
        .onAppear { name = source.name; address = source.address }
    }
}
