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
    @State private var showingPhotoPicker = false
    @State private var showingIconLibrary = false
    @State private var iconSelectionRevision = 0
    @State private var showingMoreSettings = false
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: AddressField?

    private enum AddressField: Hashable { case host, port, path }

    var body: some View {
        NavigationStack {
            settingsForm
            .background(Color(uiColor: .systemGroupedBackground))
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

    private var identityFields: some View {
        HStack(spacing: 16) {
            Menu {
                Button("从照片选择", systemImage: "photo") { showingPhotoPicker = true }
                Button("从图标库选择", systemImage: "square.grid.2x2") { showingIconLibrary = true }
                Button("使用默认图标", systemImage: "arrow.counterclockwise") {
                    iconSelectionRevision += 1
                    iconData = nil
                    selectedIcon = nil
                }
            } label: {
                sourceIcon
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .symbolRenderingMode(.palette).foregroundStyle(.white, .gray)
                            .offset(x: 3, y: 3)
                    }
            }
            .buttonStyle(.plain)

            VStack(spacing: 0) {
                fieldRow("名称") { TextField("", text: $title) }
                    .padding(.vertical, 11)
                Divider()
                fieldRow("备注") { TextField("", text: $note, axis: .vertical).lineLimit(1...3) }
                    .padding(.vertical, 11)
            }
            .padding(.horizontal, 16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
        .padding(.top, 12)
    }

    private var settingsForm: some View {
        Form {
            Section {
                identityFields
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section("服务器") {
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
                Toggle("HTTPS", isOn: $schemeIsHTTPS)
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
                ForEach(alternateAddresses, id: \.self) { Text($0).lineLimit(1) }
                    .onDelete { alternateAddresses.remove(atOffsets: $0) }
                HStack {
                    TextField("添加线路地址", text: $alternateAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("添加") { addAlternateAddress() }
                        .disabled(alternateAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private func fieldRow<Field: View>(_ label: String, @ViewBuilder field: () -> Field) -> some View {
        EmbyFormRow {
            Text(label).lineLimit(1).minimumScaleFactor(0.75)
            field()
        }
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
                   let savedSource = source.flatMap({ original in library.sources.first(where: { $0.id == original.id }) })
                    ?? library.sources.last(where: { $0.kind == .emby && $0.emby?.serverAddress == trimmedAddress }),
                   let fetched = try? await EmbyRepository.shared.alternateAddresses(for: savedSource) {
                    var refreshed = library.embyConfiguration(for: savedSource.id) ?? configuration
                    refreshed.alternateAddresses = EmbyRouteOptions.unique((refreshed.alternateAddresses ?? []) + fetched)
                        .filter { EmbyRouteOptions.key($0) != EmbyRouteOptions.key(refreshed.serverAddress) }
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
        guard !value.isEmpty else { return }
        do {
            _ = try EmbyAPIClient(configuration: .init(title: "", note: "", serverAddress: value, username: ""), token: nil, deviceID: "validation")
        } catch { errorMessage = error.localizedDescription; return }
        guard EmbyRouteOptions.key(value) != EmbyRouteOptions.key(serverAddress),
              !alternateAddresses.contains(where: { EmbyRouteOptions.key($0) == EmbyRouteOptions.key(value) }) else { return }
        alternateAddresses.append(value)
        alternateAddress = ""
    }
}

/// Keeps the label column aligned without forcing a height on the text fields.
private struct EmbyFormRow: Layout {
    private let gap: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? (subviews[0].sizeThatFits(.unspecified).width + gap + subviews[1].sizeThatFits(.unspecified).width)
        let labelWidth = width * 0.25
        let fieldWidth = max(0, width - labelWidth - gap)
        let labelHeight = subviews[0].sizeThatFits(ProposedViewSize(width: labelWidth, height: nil)).height
        let fieldHeight = subviews[1].sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil)).height
        return CGSize(width: width, height: max(labelHeight, fieldHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let labelWidth = bounds.width * 0.25
        let fieldX = labelWidth + gap
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: labelWidth, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.minX + fieldX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: max(0, bounds.width - fieldX), height: nil))
    }
}
