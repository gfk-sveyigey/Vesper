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
    @State private var editingSource: DanmakuAPISource?
    @State private var deletingSource: DanmakuAPISource?
    private var enabledCount: Int { store.sources.filter(\.enabled).count }

    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "弹幕 API", symbol: "network",
                              description: "管理在线弹幕来源，播放时选择作品与剧集。")
            SettingsSection {
                HStack {
                    Text("已添加的 API").font(.headline)
                    Spacer()
                    Text(String(format: VesperLocalization.string("%lld / %lld 已启用"), enabledCount, store.sources.count))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                if store.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("尚未添加 API").font(.subheadline.weight(.medium))
                        Text("添加兼容弹弹play的服务后，即可在播放界面搜索在线弹幕。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                } else {
                    ForEach(store.sources) { source in
                        sourceRow(source)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("删除", role: .destructive) { deletingSource = source }
                                Button("编辑") { editingSource = source }.tint(.accentColor)
                            }
                    }
                }
                Button {
                    editingSource = .init(name: "", address: "")
                } label: {
                    Label("添加弹幕 API", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            } footer: {
                Text("点击来源编辑，使用右侧开关控制是否可选。地址仅显示域名，不展示路径中的访问令牌。")
            }
            SettingsSection("接口说明") {
                Label("弹弹play兼容格式", systemImage: "checkmark.circle")
                Text("支持 LogVar / danmu_api 等兼容服务。基础地址可包含代理路径或访问令牌前缀。")
                    .font(.footnote).foregroundStyle(.secondary)
            } footer: {
                Text("配置仅保存在本机。搜索时发送搜索词与所选作品、剧集 ID，不会附带 Emby 凭据。")
            }
        }
        .navigationTitle("弹幕 API")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加弹幕 API", systemImage: "plus") {
                    editingSource = .init(name: "", address: "")
                }
            }
        }
        .sheet(item: $editingSource) { source in
            NavigationStack {
                DanmakuAPIEditor(source: source,
                                 isNew: !store.sources.contains(where: { $0.id == source.id })) { updated in
                    if let index = store.sources.firstIndex(where: { $0.id == updated.id }) {
                        store.sources[index] = updated
                    } else {
                        store.sources.append(updated)
                    }
                }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog("删除此弹幕 API？", isPresented: Binding(
            get: { deletingSource != nil }, set: { if !$0 { deletingSource = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let source = deletingSource { store.sources.removeAll { $0.id == source.id } }
                deletingSource = nil
            }
            Button("取消", role: .cancel) { deletingSource = nil }
        } message: {
            Text("仅移除 API 配置，不影响已加载的弹幕。")
        }
    }

    private func sourceRow(_ source: DanmakuAPISource) -> some View {
        HStack(spacing: 12) {
            Button {
                editingSource = source
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "network")
                        .font(.title3)
                        .foregroundStyle(source.enabled ? Color.accentColor : .secondary)
                        .frame(width: 32, height: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: source.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                        Text(verbatim: URL(string: source.address)?.host ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("编辑此 API")
            Toggle("启用 API", isOn: Binding(
                get: { store.sources.first(where: { $0.id == source.id })?.enabled ?? false },
                set: { value in
                    if let index = store.sources.firstIndex(where: { $0.id == source.id }) {
                        store.sources[index].enabled = value
                    }
                }
            ))
            .labelsHidden()
            .accessibilityLabel(Text("启用 API：") + Text(verbatim: source.name))
        }
        .padding(.vertical, 4)
    }
}

struct DanmakuAPISearchView: View {
    @ObservedObject var document: PlayerDanmaku
    var item: MediaItem? = nil
    var mediaSource: MediaSource? = nil
    @ObservedObject private var store = DanmakuAPISources.shared
    @Environment(\.dismiss) private var dismiss
    @State private var sourceID: UUID?
    @State private var keyword = ""
    @State private var works: [DanmakuAPIItem] = []
    @State private var status = ""
    @State private var busy = false
    @State private var prepared = false
    @State private var preparing = false
    @State private var operation: Task<Void, Never>?
    private var sources: [DanmakuAPISource] { store.sources.filter(\.enabled) }
    private var source: DanmakuAPISource? { sources.first { $0.id == sourceID } }

    var body: some View {
        SettingsPage {
            SettingsSection("搜索作品") {
                SettingsPicker("弹幕 API", selection: $sourceID) {
                    Text("请选择").tag(Optional<UUID>.none)
                    ForEach(sources) { source in Text(source.name).tag(Optional(source.id)) }
                }.disabled(busy)
                TextField("作品名称", text: $keyword).submitLabel(.search).onSubmit { search() }
                Button("搜索", action: search)
                    .disabled(busy || preparing || source == nil || keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if preparing { ProgressView("正在读取剧集信息…") }
                if busy { ProgressView() }
                if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
            } footer: {
                Text("已按当前视频预填搜索词，可手动修改。选择作品后进入剧集列表。")
            }
            if !works.isEmpty, let source {
                SettingsSection("搜索结果") {
                    ForEach(works) { work in
                        NavigationLink {
                            DanmakuAPIEpisodesView(document: document, source: source, work: work) { dismiss() }
                        } label: {
                            Text(verbatim: work.title)
                        }
                    }
                }
            }
            SettingsSection {
                NavigationLink("管理弹幕 API") { DanmakuAPISettingsView() }
            }
        }
        .navigationTitle("搜索弹幕")
        .toolbarTitleDisplayMode(.inline)
        .task { await prepareSearch() }
        .onChange(of: sourceID) { _, _ in works = []; status = "" }
        .onDisappear { operation?.cancel() }
    }
    private func prepareSearch() async {
        guard !prepared else { return }
        prepared = true
        preparing = true
        defer { preparing = false }
        if sourceID == nil { sourceID = sources.first?.id }
        guard let item else { return }
        let fallback = item.title
        keyword = fallback
        guard let mediaSource, mediaSource.kind == .emby,
              let detail = try? await EmbyRepository.shared.detailMetadata(for: item, source: mediaSource),
              !Task.isCancelled else { return }
        guard let series = detail.series else { return }
        let count = try? await EmbyRepository.shared.seriesSeasonCount(for: series, source: mediaSource)
        guard !Task.isCancelled else { return }
        let query = DanmakuSearchQuery.make(title: series.title, season: detail.seasonNumber, seasonCount: count)
        // Metadata must never overwrite a query the user has already edited.
        if keyword == fallback { keyword = query }
    }
    private func search() {
        guard !busy, !preparing, let source else { return }
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        operation?.cancel(); busy = true; status = ""; works = []
        operation = Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await DanmakuAPI.search(source: source, keyword: query)
                try Task.checkCancellation()
                works = result
                if result.isEmpty { status = VesperLocalization.string("未找到匹配的作品。") }
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
}

private struct DanmakuAPIEpisodesView: View {
    @ObservedObject var document: PlayerDanmaku
    let source: DanmakuAPISource
    let work: DanmakuAPIItem
    let onLoaded: () -> Void
    @State private var episodes: [DanmakuAPIItem] = []
    @State private var status = ""
    @State private var loading = true
    @State private var downloading = false
    @State private var operation: Task<Void, Never>?
    @State private var retryRevision = 0

    var body: some View {
        SettingsPage {
            SettingsSection {
                Text(verbatim: work.title).font(.headline)
                LabeledContent("弹幕来源", value: source.name)
            }
            SettingsSection("选择剧集") {
                if loading { ProgressView() }
                if downloading { ProgressView("正在加载弹幕…") }
                if !status.isEmpty {
                    Text(status).foregroundStyle(.secondary)
                    if episodes.isEmpty { Button("重新加载") { retryRevision += 1 } }
                }
                ForEach(episodes) { episode in
                    Button { load(episode) } label: { Text(verbatim: episode.title) }
                        .disabled(loading || downloading)
                }
            } footer: {
                Text("选择与当前视频对应的剧集。加载成功后替换当前弹幕，失败时保留原有弹幕。")
            }
        }
        .navigationTitle("选择剧集")
        .toolbarTitleDisplayMode(.inline)
        .task(id: retryRevision) {
            loading = true; status = ""
            defer { loading = false }
            do {
                let result = try await DanmakuAPI.episodes(source: source, id: work.id)
                try Task.checkCancellation()
                episodes = result
                if result.isEmpty { status = VesperLocalization.string("该作品暂无剧集。") }
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
        .onDisappear { operation?.cancel() }
    }
    private func load(_ episode: DanmakuAPIItem) {
        guard !downloading else { return }
        downloading = true; status = ""
        operation = Task { @MainActor in
            defer { downloading = false }
            do {
                let comments = try await DanmakuAPI.comments(source: source, id: episode.id)
                try Task.checkCancellation()
                document.comments = comments
                document.filename = "\(source.name) · \(episode.title)"
                document.offset = 0
                onLoaded()
            } catch { if !Task.isCancelled { status = error.localizedDescription } }
        }
    }
}

private struct DanmakuAPIEditor: View {
    let source: DanmakuAPISource
    let isNew: Bool
    let onSave: (DanmakuAPISource) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var enabled: Bool
    @State private var error: String?

    init(source: DanmakuAPISource, isNew: Bool, onSave: @escaping (DanmakuAPISource) -> Void) {
        self.source = source; self.isNew = isNew; self.onSave = onSave
        _name = State(initialValue: source.name)
        _address = State(initialValue: source.address)
        _enabled = State(initialValue: source.enabled)
    }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "弹幕 API", symbol: "network", description: "配置在线弹幕服务的名称与接口地址。")
            SettingsSection("基本信息") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("名称").font(.caption).foregroundStyle(.secondary)
                    TextField("为此 API 命名", text: $name)
                }.padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text("API 基础地址").font(.caption).foregroundStyle(.secondary)
                    TextField("HTTPS 地址", text: $address, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .privacySensitive()
                }.padding(.vertical, 4)
            } footer: {
                Text("填写 HTTPS 基础地址，可保留路径前缀，也可填写到 /api/v2。不支持带查询参数的地址。")
            }
            SettingsSection {
                LabeledContent("接口格式", value: "弹弹play兼容")
                Toggle("启用此 API", isOn: $enabled)
            } footer: {
                Text("停用后不出现在在线弹幕的来源选项中，不影响已经加载的弹幕。")
            }
            if let error {
                SettingsSection {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(isNew ? "添加弹幕 API" : "编辑弹幕 API")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(!canSave) }
        }
    }
    private func save() {
        var edited = source
        edited.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.enabled = enabled
        do {
            _ = try edited.endpoint([])
            onSave(edited)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
