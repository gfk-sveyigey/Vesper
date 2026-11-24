import SwiftUI
import Photos
import PhotosUI
import UIKit

private enum SourcesAlert: Hashable, Identifiable {
    case addSource
    case localNetwork
    case refreshRoutes(String)
    case privacyPasswordRequired
    var id: Self { self }
}

struct SourcesView: View {
    private enum SourceManagementRequest: Identifiable {
        case icon(MediaSource)
        case routes(MediaSource)
        var id: String {
            switch self {
            case .icon(let source): "icon-\(source.id)"
            case .routes(let source): "routes-\(source.id)"
            }
        }
    }

    private struct EditorRequest: Identifiable {
        let source: MediaSource
        var id: UUID { source.id }
    }

    var headerVisibilityChanged: (Bool) -> Void = { _ in }
    @EnvironmentObject private var library: SourceLibrary
    @EnvironmentObject private var playback: PlaybackSession
    @EnvironmentObject private var appLock: AppLock
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @State private var activeAlert: SourcesAlert?
    @State private var isShowingEmbyEditor = false
    @State private var editingEmby: EditorRequest?
    @State private var sourceManagement: SourceManagementRequest?
    @State private var refreshingRoutes: Set<UUID> = []
    @State private var showingOrder = false

    var body: some View {
        VesperRootScrollView(title: "来源") {
            if library.visibleSources.isEmpty {
                VesperCenteredEmptyContent(message: "未配置来源", symbol: AppSection.sources.symbol)
            } else {
                VStack(spacing: 0) {
                    ForEach(library.visibleSources) { source in
                        SourceListRow(source: source, isSelected: source.id == library.selectedID,
                                      latency: library.routeLatencies[source.id], select: {
                            selectSource(source)
                        }) {
                            if library.isPrivacyModeEnabled {
                                Button(library.isProtected(source) ? "取消保护" : "保护",
                                       systemImage: library.isProtected(source) ? "lock.open" : "lock") {
                                    library.setProtected(!library.isProtected(source), for: source)
                                }
                            }
                            if let configuration = source.emby {
                                Button("编辑来源", systemImage: "pencil") {
                                    editingEmby = EditorRequest(source: source)
                                }
                                Button("修改图标", systemImage: "photo") {
                                    sourceManagement = .icon(source)
                                }
                                Button("编辑线路", systemImage: "point.3.connected.trianglepath.dotted") {
                                    sourceManagement = .routes(source)
                                }
                                Button("刷新线路", systemImage: "arrow.clockwise") { refreshRoutes(source.id) }
                                    .disabled(refreshingRoutes.contains(source.id))
                                Menu("切换线路", systemImage: "arrow.left.arrow.right") {
                                    let primary = configuration.primaryRoute
                                    ForEach([primary] + configuration.backupRoutes, id: \.self) { address in
                                        let key = EmbyRouteOptions.key(address)
                                        let name = address == primary ? VesperLocalization.string("主线路") :
                                            configuration.alternateRouteNames?[key] ?? URLComponents(string: address)?.host ?? address
                                        Button {
                                            library.switchEmbyRoute(source.id, address: address)
                                        } label: {
                                            Label {
                                                Text(verbatim: name)
                                            } icon: {
                                                Image(systemName: "checkmark")
                                                    .opacity(key == EmbyRouteOptions.key(configuration.serverAddress) ? 1 : 0)
                                                    .accessibilityHidden(key != EmbyRouteOptions.key(configuration.serverAddress))
                                            }
                                        }
                                    }
                                }
                            }
                            Button("移除来源", systemImage: "trash", role: .destructive) { library.remove(source.id) }
                        }
                        .accessibilityAction(named: Text("移除来源")) { library.remove(source.id) }
                        if source.id != library.visibleSources.last?.id {
                            Divider().padding(.leading, iconInset)
                        }
                    }
                    if library.storageFailed { Text("来源设置保存失败").foregroundStyle(.red) }
                }
                .padding(.horizontal, 20)
            }
        } actions: {
            HStack(spacing: 0) {
                if library.canUsePrivacyMode {
                    Button { togglePrivacyMode() } label: {
                        actionIcon(library.isPrivacyModeEnabled ? "eye" : "eye.slash")
                    }
                    .accessibilityLabel(library.isPrivacyModeEnabled ? "退出隐私模式" : "进入隐私模式")
                }
                Button { showingOrder = true } label: { actionIcon("arrow.up.arrow.down") }
                    .accessibilityLabel("调整来源顺序")
                    .disabled(library.visibleSources.count < 2)
                Button { library.testRouteLatencies() } label: { actionIcon("arrow.clockwise") }
                    .accessibilityLabel("测试延迟")
                    .disabled(library.isTestingRouteLatency || !library.visibleSources.contains { $0.kind == .emby })
                addMenu
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Capsule())
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .privacyPasswordRequired:
                Alert(title: Text("密码保护未开启"), message: Text("请先在设置中启用密码保护。"),
                      dismissButton: .cancel(Text("好")))
            case .addSource:
                Alert(title: Text("无法添加来源"), message: Text("请检查相册访问权限或本地视频文件。"),
                      dismissButton: .cancel(Text("好")))
            case .refreshRoutes(let message):
                Alert(title: Text("无法刷新线路"), message: Text(verbatim: message),
                      dismissButton: .cancel(Text("好")))
            case .localNetwork:
                Alert(title: Text("无法访问本地网络"),
                      message: Text("请在系统设置中允许 Vesper 访问本地网络，然后重新选择 Emby 来源。"),
                      primaryButton: .default(Text("前往设置")) {
                          guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                          UIApplication.shared.open(url)
                      },
                      secondaryButton: .cancel(Text("取消")))
            }
        }
        .onChange(of: isShowingEmbyEditor || editingEmby != nil || sourceManagement != nil || showingOrder, initial: true) { _, presentsEditor in
            headerVisibilityChanged(!presentsEditor)
        }
        .sheet(isPresented: $isShowingEmbyEditor) { EmbySourceEditor(source: nil) }
        .sheet(item: $editingEmby) { request in
            EmbySourceEditor(source: request.source)
        }
        .sheet(item: $sourceManagement) { request in
            switch request {
            case .icon(let source):
                SourceIconEditSheet(source: source)
            case .routes(let source):
                SourceRouteManagementSheet(source: source)
            }
        }
        .sheet(isPresented: $showingOrder) { SourceOrderSheet() }
    }

    private func togglePrivacyMode() {
        if library.isPrivacyModeEnabled {
            // Playback can belong to a source other than the selected browsing source.
            if let item = playback.currentItem, library.canUsePrivacyMode,
               library.protectedSourceIDs.contains(item.id.sourceID) {
                playback.stop()
            }
            library.setPrivacyMode(false)
        } else if appLock.isEnabled {
            appLock.requestAuthentication(.sourcePrivacy) {
                library.setPrivacyMode(true)
                library.testProtectedRouteLatencies()
            }
        } else {
            activeAlert = .privacyPasswordRequired
        }
    }

    private var iconInset: CGFloat {
        let side = max(0, layout[.sourceListRowHeight] - layout[.sourceListIconTop] - layout[.sourceListIconBottom])
        return CGFloat(side + layout[.sourceListIconLeading] + layout[.sourceListIconTrailing]) + 12
    }

    private func actionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func selectSource(_ source: MediaSource) {
        guard source.id != library.selectedID else { return }
        guard source.kind == .emby, let address = source.emby?.serverAddress,
              LocalNetworkPermissionProbe.isLocalAddress(address) else {
            library.select(source.id)
            return
        }
        Task {
            if await LocalNetworkPermissionProbe.check(address) == .denied {
                activeAlert = .localNetwork
            } else {
                library.select(source.id)
            }
        }
    }

    private func refreshRoutes(_ id: UUID) {
        guard refreshingRoutes.insert(id).inserted else { return }
        Task {
            defer { refreshingRoutes.remove(id) }
            do {
                try await library.refreshEmbyRoutes(id)
            } catch {
                activeAlert = .refreshRoutes(error.localizedDescription)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            if !library.sources.contains(where: { $0.kind == .photos }) {
                Button("相册视频", systemImage: "play.rectangle.on.rectangle") { addPhotos() }
            }
            if !library.sources.contains(where: { $0.kind == .local }) {
                Button("本地视频", systemImage: "folder") { addLocalVideos() }
            }
            Button { isShowingEmbyEditor = true } label: {
                Label("Emby", image: "EmbyLogo")
            }
        } label: {
            actionIcon("plus")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加来源")
    }

    private func addPhotos() {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if status == .authorized || status == .limited {
                library.addDeviceSource(kind: .photos, name: VesperLocalization.string("相册视频"))
            } else { activeAlert = .addSource }
        }
    }

    private func addLocalVideos() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
            library.addDeviceSource(
                kind: .local,
                name: VesperLocalization.string("本地视频")
            )
        } catch {
            activeAlert = .addSource
        }
    }
}

private struct SourceOrderSheet: View {
    @EnvironmentObject private var library: SourceLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsPage {
                SettingsSection {
                    ForEach(library.visibleSources) { source in
                        Text(verbatim: source.localizedSourceName)
                    }
                    .onMove(perform: library.moveSources)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("调整来源顺序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}

private struct SourceIconEditSheet: View {
    let source: MediaSource
    @EnvironmentObject private var library: SourceLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var iconData: Data?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showingIconLibrary = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        Group {
                            if let iconData, let image = UIImage(data: iconData) {
                                Image(uiImage: image).resizable().scaledToFit()
                            } else {
                                Image("EmbyLogo").resizable().scaledToFit().padding(8)
                            }
                        }
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                        Spacer()
                    }
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("从照片选择", systemImage: "photo")
                    }
                    Button("从图标库选择", systemImage: "square.grid.2x2") {
                        showingIconLibrary = true
                    }
                    Button("使用默认图标", systemImage: "arrow.counterclockwise", role: .destructive) {
                        iconData = nil
                    }
                }
            }
            .navigationTitle("修改图标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存", systemImage: "checkmark") {
                        library.updateEmbyIcon(source.id, iconData: iconData)
                        dismiss()
                    }
                }
            }
        }
        .onAppear { iconData = source.emby?.iconData }
        .onChange(of: selectedPhoto) { _, photo in
            guard let photo else { return }
            Task {
                if let data = try? await photo.loadTransferable(type: Data.self),
                   UIImage(data: data) != nil, !Task.isCancelled {
                    iconData = data
                }
            }
        }
        .sheet(isPresented: $showingIconLibrary) {
            EmbyLibraryIconPicker { iconData = $0 }
        }
    }
}

private struct SourceRouteManagementSheet: View {
    let source: MediaSource
    @EnvironmentObject private var library: SourceLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var routes: [EmbyRouteDraft] = []
    @State private var editingRoute: EmbyRouteDraft?
    @State private var errorMessage: String?

    private var activeKey: String { EmbyRouteOptions.key(source.emby?.serverAddress ?? "") }

    @ViewBuilder
    private func routeTitle(for route: EmbyRouteDraft) -> some View {
        if route.id == routes.first?.id {
            Text("主线路")
        } else {
            Text(verbatim: route.displayName)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("线路") {
                    ForEach(routes) { route in
                        Button { editingRoute = route } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    routeTitle(for: route)
                                    if EmbyRouteOptions.key(route.address) == activeKey {
                                        Spacer()
                                        Text("正在使用").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(verbatim: route.address)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            deleteRouteButton(route)
                        }
                    }
                    Button("添加线路", systemImage: "plus") { editingRoute = EmbyRouteDraft() }
                }
                Section {
                    Text("当前使用中的线路不能删除；可编辑其地址，线路名称保持不变。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("编辑线路")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存", systemImage: "checkmark", action: saveRoutes)
                        .disabled(routes.isEmpty)
                }
            }
            .sheet(item: $editingRoute) { route in
                EmbyRouteEditor(draft: route, otherAddresses: routes.filter { $0.id != route.id }.map(\.address)) { updated in
                    var saved = updated
                    if EmbyRouteOptions.key(route.address) == activeKey {
                        saved.name = route.name
                        saved.fromServer = route.fromServer
                    }
                    if let index = routes.firstIndex(where: { $0.id == saved.id }) {
                        routes[index] = saved
                    } else {
                        routes.append(saved)
                    }
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
        .onAppear(perform: loadRoutes)
    }

    private func loadRoutes() {
        guard let configuration = library.embyConfiguration(for: source.id) else { return }
        let serverKeys = Set((configuration.serverRouteAddresses ?? []).map(EmbyRouteOptions.key))
        routes = ([configuration.primaryRoute] + configuration.backupRoutes).map { address in
            let key = EmbyRouteOptions.key(address)
            return EmbyRouteDraft(address: address,
                                  name: configuration.alternateRouteNames?[key] ?? "",
                                  fromServer: serverKeys.contains(key))
        }
    }

    private func deleteRouteButton(_ route: EmbyRouteDraft) -> some View {
        let isActive = EmbyRouteOptions.key(route.address) == activeKey
        return Button(role: .destructive) {
            routes.removeAll { $0.id == route.id }
        } label: {
            Label("删除", systemImage: "trash")
        }
        .disabled(routes.count <= 1 || isActive)
    }

    private func saveRoutes() {
        do {
            try library.updateEmbyRoutes(source.id, routes: routes)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension MediaSource {
    var localizedSourceName: String {
        switch kind {
        case .local: VesperLocalization.string("本地视频")
        case .photos: VesperLocalization.string("相册视频")
        default: name
        }
    }
}

private enum SourceLatencyPalette {
    typealias LatencyColorStop = (milliseconds: Int, red: Double, green: Double, blue: Double)
    static let light: [LatencyColorStop] = [
        (500, 0.08, 0.45, 0.24),
        (1000, 0.34, 0.43, 0.08),
        (2000, 0.65, 0.32, 0.04),
        (5000, 0.73, 0.15, 0.18),
    ]
    static let dark: [LatencyColorStop] = [
        (500, 0.31, 0.85, 0.52),
        (1000, 0.70, 0.86, 0.27),
        (2000, 1.00, 0.64, 0.26),
        (5000, 1.00, 0.38, 0.41),
    ]
}

private struct SourceListRow<Actions: View>: View {
    @EnvironmentObject private var playback: PlaybackSession
    @EnvironmentObject private var library: SourceLibrary
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @AppStorage("appearance.accent") private var accent = "vesper"
    let source: MediaSource
    let isSelected: Bool
    let latency: Int?
    let select: () -> Void
    let actions: Actions
    @State private var summary: EmbySourceSummary?

    init(source: MediaSource, isSelected: Bool, latency: Int?, select: @escaping () -> Void,
         @ViewBuilder actions: () -> Actions) {
        self.source = source
        self.isSelected = isSelected
        self.latency = latency
        self.select = select
        self.actions = actions()
    }

    private var rowHeight: CGFloat { CGFloat(layout[.sourceListRowHeight]) }
    private var iconTop: CGFloat { CGFloat(layout[.sourceListIconTop]) }
    private var iconLeading: CGFloat { CGFloat(layout[.sourceListIconLeading]) }
    private var iconBottom: CGFloat { CGFloat(layout[.sourceListIconBottom]) }
    private var iconTrailing: CGFloat { CGFloat(layout[.sourceListIconTrailing]) }
    private var iconSide: CGFloat { max(0, rowHeight - iconTop - iconBottom) }

    private var routeTitle: String? {
        guard let configuration = source.emby else { return nil }
        let current = configuration.serverAddress
        guard EmbyRouteOptions.key(current) != EmbyRouteOptions.key(configuration.primaryRoute) else {
            return VesperLocalization.string("主线路")
        }
        return configuration.alternateRouteNames?[EmbyRouteOptions.key(current)] ?? URLComponents(string: current)?.host ?? current
    }

    private var latencyColor: Color {
        guard let latency else { return .secondary }
        let stops = colorScheme == .dark ? SourceLatencyPalette.dark : SourceLatencyPalette.light
        for (lower, upper) in zip(stops, stops.dropFirst()) where latency <= upper.milliseconds {
            let fraction = Double(max(latency, lower.milliseconds) - lower.milliseconds)
                / Double(upper.milliseconds - lower.milliseconds)
            return Color(
                red: lower.red + (upper.red - lower.red) * fraction,
                green: lower.green + (upper.green - lower.green) * fraction,
                blue: lower.blue + (upper.blue - lower.blue) * fraction
            )
        }
        guard let last = stops.last else { return .secondary }
        return Color(red: last.red, green: last.green, blue: last.blue)
    }

    var body: some View {
        Button(action: select) {
            rowContent
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            actions
        } preview: {
            rowContent
                .padding(12)
                .frame(width: 320)
                .background(Color(uiColor: .systemBackground))
        }
        .task(id: source.emby?.serverAddress) {
            guard source.kind == .emby else { summary = nil; return }
            let updatedSummary = try? await library.catalog.sourceSummary(for: source)
            if !Task.isCancelled { summary = updatedSummary }
        }
    }

    private var rowContent: some View {
            HStack(spacing: 0) {
                icon
                    .frame(width: iconSide, height: iconSide)
                    .padding(.top, iconTop)
                    .padding(.leading, iconLeading)
                    .padding(.bottom, iconBottom)
                    .padding(.trailing, iconTrailing)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(verbatim: source.localizedSourceName)
                            .font(.body.weight(.medium))
                        if library.isProtected(source) {
                            Image(systemName: "lock.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("受密码保护")
                        }
                        if let routeTitle {
                            Text("·").foregroundStyle(.secondary).font(.caption)
                            Text(verbatim: routeTitle).foregroundStyle(.secondary).font(.caption)
                            Text("·").foregroundStyle(.secondary).font(.caption)
                            latencyLabel
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(latencyColor)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)

                    Text(verbatim: countLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    lastPlayedLine
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.trailing, 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VesperTheme.accent(accent))
                        .padding(.trailing, 14)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight, alignment: .center)
            .contentShape(Rectangle())
    }

    private var latencyLabel: Text {
        if let latency { return Text(verbatim: "\(latency) ms") }
        switch library.connectionStatus(for: source) {
        case .checking: return Text("测试中")
        case .normal, .verified, .failed: return Text("测试失败")
        }
    }

    @ViewBuilder private var icon: some View {
        if source.kind == .emby {
            if let data = source.emby?.iconData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: min(8, iconSide * 0.18)))
            } else {
                Image("EmbyLogo").resizable().scaledToFit().padding(iconSide * 0.06)
            }
        } else {
            Image(systemName: source.kind == .photos ? "play.rectangle.on.rectangle" : "folder")
                .resizable()
                .scaledToFit()
                .padding(iconSide * 0.2)
                .foregroundStyle(VesperTheme.accent(accent))
        }
    }

    private var countLine: String {
        guard source.kind == .emby else { return " " }
        guard let summary else { return "\(VesperLocalization.string("电影")) — · \(VesperLocalization.string("剧集")) —" }
        return "\(VesperLocalization.string("电影")) \(summary.movieCount) · \(VesperLocalization.string("剧集")) \(summary.seriesCount)"
    }

    private var lastPlayedLine: Text {
        let localDate = playback.history.lazy.filter { $0.source.id == source.id }.map(\.watchedAt).max()
        let date = [localDate, summary?.lastPlayed].compactMap { $0 }.max()
        guard let date else { return Text("—") }
        return Text(verbatim: date.formatted(.relative(presentation: .numeric)))
    }
}
