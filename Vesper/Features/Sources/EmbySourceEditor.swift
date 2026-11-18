import SwiftUI
import PhotosUI
import UIKit

struct EmbySourceEditor: View {
    let source: MediaSource?
    @EnvironmentObject private var library: SourceLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var note = ""
    @State private var schemeIsHTTPS = true
    @State private var host = ""
    @State private var port = ""
    @State private var path = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var alternateAddress = ""
    @State private var alternateAddresses: [String] = []
    @State private var fetchAlternateAddresses = false
    @State private var syncProgress = true
    @State private var allowTranscoding = true
    @State private var strmDirectPlayback = false
    @State private var iconData: Data?
    @State private var selectedIcon: PhotosPickerItem?
    @State private var showingMoreSettings = false
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: AddressField?

    private enum AddressField: Hashable { case host, port, path }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        PhotosPicker(selection: $selectedIcon, matching: .images) {
                            sourceIcon
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "pencil.circle.fill")
                                        .symbolRenderingMode(.palette).foregroundStyle(.white, .gray)
                                        .offset(x: 4, y: 4)
                                }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("使用默认图标", systemImage: "arrow.counterclockwise") {
                                iconData = nil
                                selectedIcon = nil
                            }
                        }
                        VStack(spacing: 0) {
                            fieldRow("名称") { TextField("", text: $title) }
                            fieldRow("备注") { TextField("", text: $note, axis: .vertical).lineLimit(1...3) }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
                Section("服务器") {
                    fieldRow("HTTPS") {
                        Toggle("", isOn: $schemeIsHTTPS).labelsHidden()
                    }
                    fieldRow("域名") {
                        TextField("example.com", text: $host)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .focused($focusedField, equals: .host)
                    }
                    fieldRow("端口") {
                        TextField(schemeIsHTTPS ? "443" : "8096", text: $port)
                            .keyboardType(.numberPad).focused($focusedField, equals: .port)
                    }
                    fieldRow("路径") {
                        TextField("emby", text: $path)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focusedField, equals: .path)
                    }
                }
                Section("账户") {
                    fieldRow("用户名") {
                        TextField("", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    fieldRow("密码") {
                        HStack(spacing: 8) {
                            Group {
                                if showPassword { TextField("", text: $password) }
                                else { SecureField("", text: $password) }
                            }
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain).accessibilityLabel(showPassword ? "隐藏密码" : "显示密码")
                        }
                    }
                }
                Section("备用线路") {
                    Toggle("从服务器获取", isOn: $fetchAlternateAddresses)
                    if !fetchAlternateAddresses {
                        ForEach(alternateAddresses, id: \.self) { Text($0).lineLimit(1) }
                            .onDelete { alternateAddresses.remove(atOffsets: $0) }
                        HStack {
                            TextField("添加线路地址", text: $alternateAddress)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            Button("添加") { addAlternateAddress() }
                                .disabled(alternateAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                Section("高级功能") {
                    Toggle("STRM 直连", isOn: $strmDirectPlayback)
                }
                Section {
                    DisclosureGroup("更多设置", isExpanded: $showingMoreSettings) {
                        Toggle("同步播放进度", isOn: $syncProgress)
                        Toggle("允许服务器转码", isOn: $allowTranscoding)
                    }
                }
                if let errorMessage { Text(verbatim: errorMessage).foregroundStyle(.red) }
            }
            .navigationTitle(source == nil ? "添加 Emby 来源" : "编辑 Emby 来源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { save() }.disabled(saving || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .onAppear(perform: loadSource)
        .onChange(of: focusedField) { oldValue, newValue in
            if oldValue == .host && newValue != .host { parseFullAddressIfNeeded() }
        }
        .onChange(of: selectedIcon) { _, item in
            Task { iconData = try? await item?.loadTransferable(type: Data.self) }
        }
        .interactiveDismissDisabled(saving)
    }

    private var sourceIcon: some View {
        Group {
            if let iconData, let image = UIImage(data: iconData) { Image(uiImage: image).resizable().scaledToFill() }
            else { Image("EmbyLogo").resizable().scaledToFit().padding(4).background(Color.white) }
        }
        .frame(width: 56, height: 56)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .accessibilityLabel("更换 Emby 图标")
    }

    private func fieldRow<Field: View>(_ label: String, @ViewBuilder field: @escaping () -> Field) -> some View {
        GeometryReader { proxy in
            HStack(spacing: 8) {
                Text(label).frame(width: proxy.size.width * 0.25, alignment: .leading)
                field()
            }
        }
        .frame(height: 40)
    }

    private func loadSource() {
        guard let source, let configuration = library.embyConfiguration(for: source.id) else { return }
        title = configuration.title
        note = configuration.note
        username = configuration.username
        iconData = configuration.iconData
        alternateAddresses = configuration.alternateAddresses ?? []
        fetchAlternateAddresses = configuration.fetchAlternateAddresses ?? false
        syncProgress = configuration.syncPlaybackProgress ?? true
        allowTranscoding = configuration.allowServerTranscoding ?? true
        strmDirectPlayback = configuration.strmDirectPlayback ?? false
        if let components = URLComponents(string: configuration.serverAddress) {
            schemeIsHTTPS = components.scheme?.lowercased() != "http"
            host = components.host ?? ""
            port = components.port.map(String.init) ?? ""
            path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }

    private func parseFullAddressIfNeeded() {
        let input = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.contains("://"), let components = URLComponents(string: input), let parsedHost = components.host else { return }
        schemeIsHTTPS = components.scheme?.lowercased() != "http"
        host = parsedHost
        port = components.port.map(String.init) ?? ""
        path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var serverAddress: String {
        let scheme = schemeIsHTTPS ? "https" : "http"
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultPort = schemeIsHTTPS ? "443" : "8096"
        let portPart = effectivePort.isEmpty ? ":\(defaultPort)" : ":\(effectivePort)"
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return "\(scheme)://\(normalizedHost)\(portPart)" + (cleanPath.isEmpty ? "" : "/\(cleanPath)")
    }

    private func save() {
        let trimmedAddress = serverAddress
        guard let components = URLComponents(string: trimmedAddress), components.host != nil,
              components.port == nil || (1...65535).contains(components.port!) else {
            errorMessage = "服务器地址无效。"
            return
        }
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var configuration = EmbySourceConfiguration(title: resolvedTitle, note: note,
            serverAddress: trimmedAddress, username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            customHeaders: source.flatMap { library.embyConfiguration(for: $0.id)?.customHeaders } ?? [:])
        configuration.serverID = source?.emby?.serverID
        configuration.userID = source?.emby?.userID
        configuration.alternateAddresses = alternateAddresses
        configuration.fetchAlternateAddresses = fetchAlternateAddresses
        configuration.syncPlaybackProgress = syncProgress
        configuration.syncWatchedState = syncProgress
        configuration.allowServerTranscoding = allowTranscoding
        configuration.strmDirectPlayback = strmDirectPlayback
        configuration.iconData = iconData
        saving = true
        errorMessage = nil
        Task {
            do {
                if let source { try await library.updateEmby(source.id, configuration: configuration, password: password.isEmpty ? nil : password) }
                else { try await library.addEmby(configuration: configuration, password: password) }
                if fetchAlternateAddresses,
                   let savedSource = source ?? library.sources.last(where: { $0.kind == .emby && $0.emby?.serverAddress == trimmedAddress }),
                   let fetched = try? await EmbyRepository.shared.alternateAddresses(for: savedSource) {
                    var refreshed = library.embyConfiguration(for: savedSource.id) ?? configuration
                    refreshed.alternateAddresses = fetched
                    try await library.updateEmby(savedSource.id, configuration: refreshed, password: nil)
                }
                saving = false
                dismiss()
            } catch {
                saving = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addAlternateAddress() {
        let value = alternateAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !alternateAddresses.contains(value) else { return }
        alternateAddresses.append(value)
        alternateAddress = ""
    }
}

struct EmbyItemDetailView: View {
    let source: MediaSource
    let item: MediaItem
    var showsCloseButton = false
    var episode: EmbyEpisode? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var details: EmbyItemDetails?
    @State private var error: String?

    var body: some View {
        List {
            if let details {
                Section {
                    if let episode {
                        MediaThumbnail(source: source, item: item, aspectRatio: 16.0 / 9.0)
                            .mediaArtworkBorder()
                        LabeledContent("季数", value: episode.season == 0 ? String(localized: "特别篇") : String(localized: "第\(episode.season)季"))
                        if episode.displayTitle != episode.numberLabel {
                            LabeledContent("集数", value: episode.numberLabel)
                        }
                    }
                    LabeledContent("名称", value: episode?.displayTitle ?? item.title)
                    if let year = item.subtitle { LabeledContent("年份", value: year) }
                    if let duration = item.duration, duration > 0 {
                        LabeledContent("时长", value: Duration.seconds(duration).formatted(.time(pattern: .hourMinute)))
                    } else if episode != nil {
                        LabeledContent("时长", value: String(localized: "未知时长"))
                    }
                    if let synopsis = details.video.synopsis { Text(verbatim: synopsis) }
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
        .navigationTitle(episode == nil ? "媒体详情" : "单集详情").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .topBarLeading) { Button("关闭", systemImage: "xmark") { dismiss() } }
            }
        }
        .task {
            do { details = try await EmbyRepository.shared.details(for: item, source: source) }
            catch { self.error = error.localizedDescription }
        }
    }
}
