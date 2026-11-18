import SwiftUI

struct EmbySourceEditor: View {
    let source: MediaSource?
    @EnvironmentObject private var library: SourceLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var note = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var userAgent = "Vesper/1.0"
    @State private var headers = ""
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标题", text: $title)
                    TextField("备注", text: $note, axis: .vertical).lineLimit(2...4)
                }
                Section {
                    TextField("服务器地址", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(source == nil ? "密码" : "密码（留空保留登录状态）", text: $password)
                } footer: {
                    Text("支持自定义端口和反向代理子路径。建议使用 HTTPS。")
                }
                Section {
                    TextField("User-Agent", text: $userAgent)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("自定义请求头", text: $headers, axis: .vertical)
                        .lineLimit(3...8).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: {
                    Text("每行填写 名称: 值。认证头由 Vesper 管理。")
                }
                if let errorMessage { Text(verbatim: errorMessage).foregroundStyle(.red) }
                Button { save() } label: {
                    HStack {
                        Text(source == nil ? "登录并添加" : "保存")
                        Spacer()
                        if saving { ProgressView() }
                    }
                }
                .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.isEmpty || username.isEmpty)
            }
            .navigationTitle(source == nil ? "添加 Emby 来源" : "编辑 Emby 来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .onAppear {
            guard let source, let configuration = library.embyConfiguration(for: source.id) else { return }
            title = configuration.title; note = configuration.note
            address = configuration.serverAddress; username = configuration.username
            userAgent = configuration.userAgent
            headers = configuration.customHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        var values: [String: String] = [:]
        for line in headers.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: ":") else {
                errorMessage = "请求头格式错误，请使用 名称: 值。"; return
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.contains("\r") else { errorMessage = "请求头包含无效字符。"; return }
            values[name] = value
        }
        var configuration = EmbySourceConfiguration(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      note: note, serverAddress: address, username: username,
                                                      userAgent: userAgent, customHeaders: values)
        configuration.serverID = source?.emby?.serverID
        configuration.userID = source?.emby?.userID
        if let old = source?.emby, (old.serverAddress != address || old.username != username), password.isEmpty {
            errorMessage = "修改服务器或用户名后，请重新输入密码。"; return
        }
        saving = true; errorMessage = nil
        Task {
            do {
                if let source { try await library.updateEmby(source.id, configuration: configuration, password: password) }
                else { try await library.addEmby(configuration: configuration, password: password) }
                saving = false; dismiss()
            } catch { saving = false; errorMessage = error.localizedDescription }
        }
    }
}

struct EmbyItemDetailView: View {
    let source: MediaSource
    let item: MediaItem
    @EnvironmentObject private var playback: PlaybackSession
    @Environment(\.dismiss) private var dismiss
    @State private var details: EmbyItemDetails?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let details {
                    Section {
                        Text(verbatim: item.title).font(.title2.bold())
                        if let synopsis = details.video.synopsis { Text(verbatim: synopsis) }
                    }
                    if !item.isContainer {
                        Section("播放") {
                            if details.versions.isEmpty {
                                Button("播放") { playback.play(item, in: source, queue: [item]); dismiss() }
                            } else {
                                ForEach(Array(details.versions.enumerated()), id: \.offset) { _, version in
                                    Button(version.subtitle ?? "播放") {
                                        playback.play(version, in: source, queue: [version]); dismiss()
                                    }
                                }
                            }
                        }
                    }
                    Section("详细信息") {
                        if let dimensions = details.video.dimensions { LabeledContent("分辨率", value: dimensions) }
                        ForEach(Array(details.video.technical.enumerated()), id: \.offset) { _, field in
                            LabeledContent(field.label, value: field.value)
                        }
                    }
                } else if let error { Text(verbatim: error).foregroundStyle(.secondary) }
                else { ProgressView() }
            }
            .navigationTitle("媒体详情").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭", systemImage: "xmark") { dismiss() } }
            }
        }
        .task {
            do { details = try await EmbyRepository.shared.details(for: item, source: source) }
            catch { self.error = error.localizedDescription }
        }
    }
}
