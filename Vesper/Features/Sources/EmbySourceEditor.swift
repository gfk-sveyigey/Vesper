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
    @State private var alternateAddress = ""
    @State private var alternateAddresses: [String] = []
    @State private var syncProgress = true
    @State private var syncWatched = true
    @State private var allowTranscoding = true
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
                    TextField("地址", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(source == nil ? "密码" : "密码（留空保留登录状态）", text: $password)
                } footer: {
                    Text("支持直接粘贴完整地址，例如 https://example.com:8096/emby。")
                }
                Section("备用线路") {
                    ForEach(alternateAddresses, id: \.self) { value in
                        Text(value).lineLimit(1)
                    }
                    .onDelete { alternateAddresses.remove(atOffsets: $0) }
                    HStack {
                        TextField("添加备用地址", text: $alternateAddress)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("添加") { addAlternateAddress() }
                            .disabled(alternateAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } footer: {
                    Text("备用线路仅由你手动选择，不会在播放失败时自动切换。")
                }
                Section("播放") {
                    Toggle("同步播放进度", isOn: $syncProgress)
                    Toggle("同步已观看标记", isOn: $syncWatched)
                    Toggle("允许服务器转码", isOn: $allowTranscoding)
                }
                if let errorMessage { Text(verbatim: errorMessage).foregroundStyle(.red) }
                Button { save() } label: {
                    HStack {
                        Text(source == nil ? "登录并添加" : "保存")
                        Spacer()
                        if saving { ProgressView() }
                    }
                }
                .disabled(saving || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            alternateAddresses = configuration.alternateAddresses ?? []
            syncProgress = configuration.syncPlaybackProgress ?? true
            syncWatched = configuration.syncWatchedState ?? true
            allowTranscoding = configuration.allowServerTranscoding ?? true
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        var values = source.flatMap { library.embyConfiguration(for: $0.id)?.customHeaders } ?? [:]
        values = values.filter { $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame }
        let trimmedAddress = Self.normalizedAddress(address)
        guard !trimmedAddress.isEmpty else { errorMessage = "请输入服务器地址。"; return }
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.displayName(for: trimmedAddress)
            : title.trimmingCharacters(in: .whitespacesAndNewlines)
        var configuration = EmbySourceConfiguration(title: resolvedTitle,
                                                      note: note, serverAddress: trimmedAddress, username: username,
                                                      customHeaders: values)
        configuration.serverID = source?.emby?.serverID
        configuration.userID = source?.emby?.userID
        configuration.alternateAddresses = alternateAddresses
        configuration.syncPlaybackProgress = syncProgress
        configuration.syncWatchedState = syncWatched
        configuration.allowServerTranscoding = allowTranscoding
        if let old = source?.emby, (old.serverAddress != trimmedAddress || old.username != username), password.isEmpty {
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

    private func addAlternateAddress() {
        let value = alternateAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != address, !alternateAddresses.contains(value) else { return }
        alternateAddresses.append(value)
        alternateAddress = ""
    }

    private static func displayName(for address: String) -> String {
        if let components = URLComponents(string: address), let host = components.host, !host.isEmpty {
            return host
        }
        return address.split(separator: "/").first.map(String.init) ?? "Emby"
    }

    private static func normalizedAddress(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("://") { return trimmed }
        return "https://" + trimmed
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
