import SwiftUI
import PhotosUI
import UIKit

struct EmbySourceEditor: View {
    let source: MediaSource?
    enum Entry { case general, icon, routes }
    var entry: Entry = .general

    @EnvironmentObject private var library: SourceLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var title = ""
    @State private var note = ""
    @State private var username = ""
    @State private var password = ""
    @State private var routes: [EmbyRouteDraft] = []
    @State private var editingRoute: EmbyRouteDraft?
    @State private var showingIconOptions = false
    @State private var fetchAlternateAddresses = false
    @State private var syncProgress = true
    @State private var allowTranscoding = true
    @State private var strmDirectPlayback = true
    @State private var iconData: Data?
    @State private var selectedIcon: PhotosPickerItem?
    @State private var showingPhotoPicker = false
    @State private var showingIconLibrary = false
    @State private var iconSelectionRevision = 0
    @State private var saving = false
    @State private var didLoad = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                settingsForm
                    .disabled(saving)
                    .task {
                        guard !didLoad else { return }
                        didLoad = true
                        loadSource()
                        await Task.yield()
                        if entry == .routes { proxy.scrollTo("emby-routes", anchor: .top) }
                        if entry == .icon { showingIconOptions = true }
                    }
            }
            .navigationTitle(source == nil ? "添加 Emby 来源" : "编辑 Emby 来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: save) {
                        Image(systemName: saving ? "arrow.triangle.2.circlepath" : "checkmark")
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.rotate, options: .repeating, isActive: saving && !reduceMotion)
                    }
                    .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: saving)
                    .accessibilityLabel(Text(LocalizedStringKey(saving ? "正在验证来源" : "完成")))
                    .disabled(saving)
                }
            }
        }
        .confirmationDialog("更换 Emby 图标", isPresented: $showingIconOptions) { iconActions }
        .sheet(item: $editingRoute) { draft in
            EmbyRouteEditor(draft: draft, otherAddresses: routes.filter { $0.id != draft.id }.map(\.address)) { updated in
                if let index = routes.firstIndex(where: { $0.id == updated.id }) {
                    routes[index] = updated
                } else {
                    routes.append(updated)
                }
            }
        }
        .alert("无法保存来源", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(verbatim: errorMessage ?? "")
        }
        .onChange(of: selectedIcon) { _, item in
            iconSelectionRevision += 1
            let revision = iconSelectionRevision
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   UIImage(data: data) != nil, revision == iconSelectionRevision {
                    iconData = data
                }
            }
        }
        .photosPicker(isPresented: $showingPhotoPicker, selection: $selectedIcon, matching: .images)
        .sheet(isPresented: $showingIconLibrary) {
            EmbyLibraryIconPicker { data in
                iconSelectionRevision += 1
                selectedIcon = nil
                iconData = data
            }
        }
        .interactiveDismissDisabled(saving)
    }

    @ViewBuilder private var iconActions: some View {
        Button("从照片选择", systemImage: "photo") { showingPhotoPicker = true }
        Button("从图标库选择", systemImage: "square.grid.2x2") { showingIconLibrary = true }
        Button("使用默认图标", systemImage: "arrow.counterclockwise") {
            iconSelectionRevision += 1
            iconData = nil
            selectedIcon = nil
        }
    }

    private var identityFields: some View {
        HStack(spacing: 16) {
            VStack(spacing: 0) {
                TextField("名称（可选）", text: $title).padding(.vertical, 11)
                Divider()
                TextField("备注（可选）", text: $note, axis: .vertical)
                    .lineLimit(1...3).padding(.vertical, 11)
            }
            Menu {
                iconActions
            } label: {
                sourceIcon.overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil.circle.fill")
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .gray)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsForm: some View {
        Form {
            Section {
                identityFields
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section("账户") {
                LabeledContent("用户名") {
                    TextField("", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                LabeledContent("密码") {
                    SecureField(LocalizedStringKey(source?.emby?.userID == nil ? "密码" : "已保留登录凭据"),
                                text: $password)
                }
            }
            Section("线路") {
                ForEach(routes) { route in
                    Button { editingRoute = route } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if route.id == routes.first?.id {
                                Text("主线路")
                            } else {
                                Text(verbatim: route.displayName)
                            }
                            Text(verbatim: route.address)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { routes.remove(atOffsets: $0) }
                Toggle("从服务器获取", isOn: $fetchAlternateAddresses)
                Button("添加线路", systemImage: "plus") { editingRoute = EmbyRouteDraft() }
            }
            .id("emby-routes")
            Section("更多设置") {
                Toggle("同步播放进度", isOn: $syncProgress)
                Toggle("允许服务器转码", isOn: $allowTranscoding)
                Toggle("STRM 直连", isOn: $strmDirectPlayback)
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
    }

    private var sourceIcon: some View {
        Group {
            if let iconData, let image = UIImage(data: iconData) { Image(uiImage: image).renderingMode(.original).resizable().scaledToFill() }
            else { Image("EmbyLogo").resizable().scaledToFit().padding(4) }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .accessibilityLabel("更换 Emby 图标")
    }

    private func loadSource() {
        guard let source, let configuration = library.embyConfiguration(for: source.id) else { return }
        title = configuration.title
        note = configuration.note
        username = configuration.username
        iconData = configuration.iconData
        let serverKeys = Set((configuration.serverRouteAddresses ?? []).map(EmbyRouteOptions.key))
        routes = ([configuration.primaryRoute] + configuration.backupRoutes).map { address in
            let key = EmbyRouteOptions.key(address)
            return EmbyRouteDraft(address: address, name: configuration.alternateRouteNames?[key] ?? "",
                                  fromServer: serverKeys.contains(key))
        }
        fetchAlternateAddresses = configuration.fetchAlternateAddresses ?? false
        syncProgress = configuration.syncPlaybackProgress ?? true
        allowTranscoding = configuration.allowServerTranscoding ?? true
        strmDirectPlayback = configuration.strmDirectPlayback ?? true
    }

    private func save() {
        guard !saving else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        saving = true
        Task {
            defer { saving = false }
            guard let primary = routes.first else {
                errorMessage = VesperLocalization.string("请至少添加一条线路。")
                return
            }
            let previous = source.flatMap { library.embyConfiguration(for: $0.id) }
            var configuration = EmbySourceConfiguration(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines), note: note,
                serverAddress: previous?.serverAddress ?? primary.address,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                serverID: previous?.serverID, userID: previous?.userID,
                customHeaders: previous?.customHeaders ?? [:]
            )
            configuration.primaryRouteAddress = primary.address
            configuration.alternateAddresses = routes.map(\.address)
            configuration.alternateRouteNames = Dictionary(routes.filter { !$0.name.isEmpty }.map {
                (EmbyRouteOptions.key($0.address), $0.name)
            }, uniquingKeysWith: { first, _ in first })
            configuration.serverRouteAddresses = routes.dropFirst().filter(\.fromServer).map(\.address)
            configuration.fetchAlternateAddresses = fetchAlternateAddresses
            configuration.syncPlaybackProgress = syncProgress
            configuration.syncWatchedState = previous?.syncPlaybackProgress == syncProgress
                ? previous?.syncWatchedState : syncProgress
            configuration.allowServerTranscoding = allowTranscoding
            configuration.strmDirectPlayback = strmDirectPlayback
            configuration.iconData = iconData
            let newPassword = source != nil && password.isEmpty && configuration.username == previous?.username ? nil : password
            do {
                try await library.saveEmby(source?.id, configuration: configuration, password: newPassword)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct EmbyRouteDraft: Identifiable {
    let id = UUID()
    var address = ""
    var name = ""
    var fromServer = false

    var displayName: String {
        if !name.isEmpty { return name }
        return URLComponents(string: address)?.host ?? address
    }
}

private struct EmbyRouteEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EmbyRouteDraft
    @State private var host: String
    @State private var port: String
    @State private var path: String
    @State private var https: Bool
    @State private var errorMessage: String?
    let otherAddresses: [String]
    let save: (EmbyRouteDraft) -> Void

    init(draft: EmbyRouteDraft, otherAddresses: [String], save: @escaping (EmbyRouteDraft) -> Void) {
        _draft = State(initialValue: draft)
        let components = URLComponents(string: draft.address)
        _host = State(initialValue: components?.host ?? "")
        _port = State(initialValue: components?.port.map(String.init) ?? "")
        _path = State(initialValue: components?.path ?? "")
        _https = State(initialValue: components?.scheme?.lowercased() != "http")
        self.otherAddresses = otherAddresses
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("线路名称（可选）", text: $draft.name)
                TextField("域名（必填）", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("端口（可选）", text: $port).keyboardType(.numberPad)
                TextField("路径（可选）", text: $path)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("HTTPS", isOn: $https)
            }
            .navigationTitle(draft.address.isEmpty ? "添加线路" : "编辑线路")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存", systemImage: "checkmark", action: saveRoute)
                        .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("无法保存线路", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(verbatim: errorMessage ?? "")
            }
        }
    }

    private func saveRoute() {
        let domain = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let portNumber = Int(portText)
        guard !domain.isEmpty, domain.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !domain.contains(where: { "/?#@%".contains($0) }),
              portText.isEmpty || (portNumber.map { (1...65535).contains($0) } ?? false) else {
            errorMessage = VesperLocalization.string("服务器地址无效。")
            return
        }
        var components = URLComponents()
        components.scheme = https ? "https" : "http"
        components.host = domain.contains(":") && !domain.hasPrefix("[") ? "[\(domain)]" : domain
        components.port = portNumber
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = cleanPath.isEmpty ? "" : "/\(cleanPath)"
        guard let address = components.url?.absoluteString else {
            errorMessage = VesperLocalization.string("服务器地址无效。")
            return
        }
        do {
            _ = try EmbyAPIClient(configuration: .init(title: "", note: "", serverAddress: address, username: ""),
                                  token: nil, deviceID: "validation")
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let key = EmbyRouteOptions.key(address)
        guard !otherAddresses.contains(where: { EmbyRouteOptions.key($0) == key }) else {
            errorMessage = VesperLocalization.string("此线路已存在。")
            return
        }
        if EmbyRouteOptions.key(draft.address) != key { draft.fromServer = false }
        draft.address = address
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        save(draft)
        dismiss()
    }
}
