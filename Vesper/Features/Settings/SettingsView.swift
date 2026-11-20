import SwiftUI
import UIKit
import Photos

private enum SettingsRoute: Hashable {
    case tabs, appearance, logs, licenses, gestures, playback, subtitles, danmaku, debug, cache, emby, permissions

    var title: LocalizedStringKey {
        switch self {
        case .gestures: "播放手势"
        case .playback: "播放设置"
        case .subtitles: "字幕设置"
        case .danmaku: "弹幕设置"
        case .tabs: "标签设置"
        case .appearance: "外观设置"
        case .logs: "运行日志"
        case .licenses: "开源许可"
        case .debug: "调试功能"
        case .cache: "缓存管理"
        case .emby: "Emby 设置"
        case .permissions: "应用权限"
        }
    }
}

@MainActor
private final class DebugSettingsVisibility: ObservableObject {
    static let shared = DebugSettingsVisibility()
    @Published var isRevealed = false
}

struct SettingsView: View {
    @EnvironmentObject private var playback: PlaybackSession
    @AppStorage("language.code") private var languageCode = "system"
    @ObservedObject private var debugVisibility = DebugSettingsVisibility.shared

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VesperRootScrollView(title: "设置") {
            VStack(alignment: .leading, spacing: 32) {
                VStack(spacing: 0) {
                    settingsLink(.tabs, title: "标签设置", symbol: "rectangle.3.group")
                    Divider().padding(.leading, 52)
                    settingsLink(.appearance, title: "外观设置", symbol: "paintpalette")
                    Divider().padding(.leading, 52)
                    settingsLink(.logs, title: "运行日志", symbol: "doc.text")
                    Divider().padding(.leading, 52)
                    settingsLink(.cache, title: "缓存管理", symbol: "internaldrive")
                    Divider().padding(.leading, 52)
                    settingsLink(.emby, title: "Emby 设置", symbol: "server.rack")
                    Divider().padding(.leading, 52)
                    settingsLink(.permissions, title: "应用权限", symbol: "hand.raised")
                    Divider().padding(.leading, 52)
                        HStack {
                            SettingsLabel("语言设置", symbol: "globe")
                            Spacer(minLength: 12)
                            Picker(selection: $languageCode) {
                                Text("跟随系统").tag("system")
                                Text(verbatim: "简体中文").tag("zh-Hans")
                                Text(verbatim: "繁體中文").tag("zh-Hant")
                                Text(verbatim: "English").tag("en")
                                Text(verbatim: "Deutsch").tag("de")
                                Text(verbatim: "Español").tag("es")
                                Text(verbatim: "Français").tag("fr")
                                Text(verbatim: "日本語").tag("ja")
                                Text(verbatim: "한국어").tag("ko")
                            } label: { SettingsLabel("语言设置", symbol: "globe") }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .buttonStyle(.plain)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.vertical, 12)
                        .padding(.leading, 12)
                }
                VStack(spacing: 0) {
                    settingsLink(.playback, title: "播放设置", symbol: "play.circle")
                    Divider().padding(.leading, 52)
                    settingsLink(.gestures, title: "播放手势", symbol: "hand.draw")
                    Divider().padding(.leading, 52)
                    settingsLink(.subtitles, title: "字幕设置", symbol: "captions.bubble")
                    Divider().padding(.leading, 52)
                    settingsLink(.danmaku, title: "弹幕设置", symbol: "text.bubble")
                }
                VStack(spacing: 0) {
                        HStack {
                            SettingsLabel("IMDb", symbol: "film")
                            Spacer()
                            Text("尚未连接").foregroundStyle(.secondary)
                        }.padding(12)
                        Divider().padding(.leading, 56)
                        HStack(spacing: 12) {
                            Image("TraktIcon")
                                .renderingMode(.template)
                                .resizable().scaledToFit()
                                .frame(width: 20, height: 20)
                                .frame(width: 28, height: 28)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                            Text(verbatim: "Trakt").font(.body)
                                .foregroundStyle(Color(uiColor: .label))
                            Spacer()
                            Text("尚未连接").foregroundStyle(.secondary)
                        }.padding(12)
                }
                settingsLink(.licenses, title: "开源许可", symbol: "doc.plaintext")
                if debugVisibility.isRevealed {
                    VStack(spacing: 0) {
                        settingsLink(.debug, title: "调试功能", symbol: "ladybug")
                    }
                }
                Text("Vesper \(version) · Aholic")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 5) {
                        debugVisibility.isRevealed = true
                    }
            }
            .padding(.horizontal, 16)
        }
        .navigationDestination(for: SettingsRoute.self) { route in
            Group {
                switch route {
                case .gestures: PlayerGestureSettingsView()
                case .playback: PlaybackSettingsView(session: playback)
                case .subtitles: SubtitleSettingsView()
                case .danmaku: DanmakuSettingsView()
                case .tabs: TabSettingsView()
                case .appearance: AppearanceSettingsView()
                case .logs: RuntimeLogsView()
                case .licenses: PlaybackLicensesView()
                case .debug: DebugSettingsView()
                case .emby: EmbySettingsView()
                case .permissions: AppPermissionsView()
                case .cache:
                    CacheManagementView()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(.visible, for: .navigationBar)
                        .toolbarRole(.editor)
                }
            }
            .vesperNavigationTitle(route.title)
            .modifier(SettingsNavigationStyle(useSharedStyle: route != .cache))
        }
    }

    private func settingsLink(_ route: SettingsRoute, title: LocalizedStringKey, symbol: String) -> some View {
        NavigationLink(value: route) {
            HStack {
                SettingsLabel(title, symbol: symbol)
                    .foregroundStyle(Color(uiColor: .label))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

private struct EmbySettingsView: View {
    @AppStorage(EmbySkipSettings.introKey) private var skipIntro = false
    @AppStorage(EmbySkipSettings.outroKey) private var skipOutro = false
    @AppStorage(EmbySkipSettings.bodyPreloadKey) private var bodyPreload = false
    @State private var showsSkipDatabases = false
    @AppStorage(EmbyPreloadCacheSettings.nextPercentKey) private var preloadNextPercent = 90
    @AppStorage(EmbyPreloadCacheSettings.nextWiFiKey) private var preloadNextWiFi = true
    @AppStorage(EmbyPreloadCacheSettings.nextCellularKey) private var preloadNextCellular = false
    @AppStorage(EmbyPreloadCacheSettings.wifiKey) private var wifiCacheMB = 500
    @AppStorage(EmbyPreloadCacheSettings.cellularKey) private var cellularCacheMB = 500
    @AppStorage(EmbyBrowsingSettings.fullRenderingKey) private var waitsForArtwork = false
    @AppStorage(EmbyTrackPreferences.audioLanguageKey) private var audioLanguage = ""
    @AppStorage(EmbyTrackPreferences.subtitleLanguageKey) private var subtitleLanguage = ""
    @AppStorage(EmbyTrackPreferences.disableMissingSubtitleKey) private var disableMissingSubtitle = false

    var body: some View {
        SettingsPage {
            SettingsSection("跳过片头片尾") {
                Toggle("自动跳过片头", isOn: $skipIntro)
                Toggle("片尾自动播放下一集", isOn: $skipOutro)
                Button { showsSkipDatabases = true } label: {
                    HStack {
                        Text("片头片尾数据库")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
                Text("按数据库顺序查询，首个有效结果命中后停止。不支持手动标记；外部媒体 ID、季集编号和视频时长会发送给已启用的数据库。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            SettingsSection("预加载下一集") {
                Toggle("Wi-Fi 下预加载", isOn: $preloadNextWiFi)
                Toggle("蜂窝网络下预加载", isOn: $preloadNextCellular)
                Toggle("按正片时长预加载", isOn: $bodyPreload)
                Stepper(value: $preloadNextPercent, in: 1...99) {
                    LabeledContent("预加载触发进度", value: "\(preloadNextPercent)%")
                }
                Text("Aether 播放分集达到设定百分比时，按当前版本的封装、编码、动态范围及分辨率选择下一集版本，预读开头约 8 MB，必要时读取尾部索引。预读缓存不设定时过期；播放下一集时复用，停止、切换视频或网络策略不允许时清理。VLC 和原生远程 HLS 暂不支持。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SettingsSection("视频预加载缓存") {
                Picker("Wi-Fi", selection: $wifiCacheMB) {
                    ForEach(EmbyPreloadCacheSettings.choices, id: \.self) { size in
                        Text("\(size) MB").tag(size)
                    }
                }
                Picker("蜂窝网络", selection: $cellularCacheMB) {
                    ForEach(EmbyPreloadCacheSettings.choices, id: \.self) { size in
                        Text("\(size) MB").tag(size)
                    }
                }
                Text("每次打开 Emby 视频时按当前网络应用。仅限制 Aether 支持的临时媒体缓存，不是流量上限或播放器总内存限制；原生远程 HLS 和 VLC 暂不支持按容量限制。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SettingsSection {
                Toggle("完整加载后渲染", isOn: $waitsForArtwork)
            }
            SettingsSection {
                Picker("默认音轨语言", selection: $audioLanguage) {
                    ForEach(EmbyTrackPreferences.languages.indices, id: \.self) { index in
                        Text(verbatim: EmbyTrackPreferences.languages[index].1)
                            .tag(EmbyTrackPreferences.languages[index].0)
                    }
                }
                Picker("默认字幕语言", selection: $subtitleLanguage) {
                    ForEach(EmbyTrackPreferences.languages.indices, id: \.self) { index in
                        Text(verbatim: EmbyTrackPreferences.languages[index].1)
                            .tag(EmbyTrackPreferences.languages[index].0)
                    }
                }
                Toggle("无对应语言时关闭字幕", isOn: $disableMissingSubtitle)
            }
        }
        .sheet(isPresented: $showsSkipDatabases) { EmbySkipDatabasesView() }
        .task {
            if ["zho", "chi", "zh"].contains(audioLanguage) { audioLanguage = "zh-Hans" }
            if ["zho", "chi", "zh"].contains(subtitleLanguage) { subtitleLanguage = "zh-Hans" }
        }
    }
}

private struct EmbySkipDatabasesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var databases = EmbySkipSettings.databases
    @State private var editing: EmbySkipDatabase?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($databases) { $database in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(database.name, isOn: $database.enabled)
                            Text(database.address).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text(database.format.title).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if database.isBuiltin { Text("内置").font(.caption).foregroundStyle(.secondary) }
                                else { Button("编辑") { editing = database }.buttonStyle(.borderless) }
                            }
                        }
                        .deleteDisabled(database.isBuiltin)
                    }
                    .onMove { databases.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { offsets in
                        for index in offsets.sorted(by: >) where !databases[index].isBuiltin { databases.remove(at: index) }
                    }
                } footer: {
                    Text("从上到下查询。内置数据库只能启用、停用和调整顺序，不能修改或删除。自定义地址需使用 HTTPS。")
                }
                Button("添加数据库", systemImage: "plus") { adding = true }
            }
            .navigationTitle("片头片尾数据库")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .onChange(of: databases) { _, value in EmbySkipSettings.save(value) }
            .sheet(isPresented: $adding) {
                EmbySkipDatabaseEditor(database: .init(name: "", address: "https://", format: .introDB)) { databases.append($0) }
            }
            .sheet(item: $editing) { value in
                EmbySkipDatabaseEditor(database: value) { edited in
                    if let index = databases.firstIndex(where: { $0.id == edited.id }) { databases[index] = edited }
                }
            }
        }
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
                Picker("数据库格式", selection: $database.format) {
                    ForEach(EmbySkipDatabase.Format.allCases) { Text($0.title).tag($0) }
                }
                Text("IntroDB 填写 /segments 之前的地址；TheIntroDB 可填写服务根地址或含 /v4 的地址。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("数据库设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        database.name = database.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        database.address = database.address.trimmingCharacters(in: .whitespacesAndNewlines)
                        save(database); dismiss()
                    }.disabled(!valid || database.isBuiltin)
                }
            }
        }
    }
}

private struct AppPermissionsView: View {
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var isRequestingPhotos = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SettingsPage {
            SettingsSection {
                LabeledContent("照片图库", value: photoStatusText)
                if photoStatus == .notDetermined {
                    Button("请求照片访问权限", systemImage: "photo") {
                        requestPhotos()
                    }
                    .disabled(isRequestingPhotos)
                } else if photoStatus == .denied || photoStatus == .restricted {
                    Button("前往系统设置", systemImage: "arrow.up.forward.app") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }
            }
            SettingsSection {
                LabeledContent("本地网络", value: "使用时由系统请求")
                Text("连接局域网 Emby 服务器时，iOS 会显示本地网络访问提示。系统不向 App 提供权限状态查询 API。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("前往系统设置", systemImage: "arrow.up.forward.app") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
        }
        .navigationTitle("应用权限")
        .task { photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
        }
    }

    private var photoStatusText: String {
        switch photoStatus {
        case .authorized: "已允许"
        case .limited: "受限访问"
        case .denied: "未允许"
        case .restricted: "受系统限制"
        case .notDetermined: "尚未请求"
        @unknown default: "未知"
        }
    }

    private func requestPhotos() {
        isRequestingPhotos = true
        Task {
            photoStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            isRequestingPhotos = false
        }
    }
}

private struct SettingsNavigationStyle: ViewModifier {
    let useSharedStyle: Bool

    func body(content: Content) -> some View {
        if useSharedStyle { content.vesperNavigationStyle(.inline) }
        else { content }
    }
}

private struct RuntimeLogsView: View {
    @ObservedObject private var store: RuntimeLogEntries
    @AppStorage("runtimeLogs.retentionDays") private var retentionDays = 7
    @State private var loadedCount = 100
    @State private var shareFile: SharedLogFile?
    @State private var isShowingClearConfirmation = false
    @State private var isShowingExportError = false

    init() { store = AppLog.runtimeEntries }

    var body: some View {
        SettingsPage {
            Group {
                SettingsIntroCard(title: "运行日志", symbol: "doc.text", description: "查看、保留和分享运行日志。")

                if store.storageError != nil { Text("日志文件写入失败。").foregroundStyle(.red) }
                SettingsSection {
                    SettingsPicker(selection: $retentionDays) {
                        Text("无限制").tag(0)
                        ForEach([1, 3, 7, 14, 30, 90], id: \.self) { days in
                            Text(String(format: VesperLocalization.string("%d 天"), locale: VesperLocalization.locale(for: UserDefaults.standard.string(forKey: "language.code") ?? "system"), arguments: [days])).tag(days)
                        }
                    } label: { Text("保留时间") }
                    .pickerStyle(.menu)
                }
                SettingsSection {
                    if store.entries.isEmpty {
                        ContentUnavailableView("暂无运行日志", systemImage: "doc.text")
                    } else {
                        ForEach(store.entries.suffix(loadedCount).reversed()) { entry in
                            Text(entry.message)
                                .font(.system(.footnote, design: .monospaced))
                                .contextMenu {
                                    Button("复制日志", systemImage: "doc.on.doc") {
                                        UIPasteboard.general.string = entry.message
                                    }
                                }
                        }
                    }
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .background(VesperTheme.background)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    store.prepareExportFile { result in
                        switch result {
                        case .success(let url): shareFile = SharedLogFile(url: url)
                        case .failure: isShowingExportError = true
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("导出日志")
                .disabled(store.entries.isEmpty)
                Button(role: .destructive) { isShowingClearConfirmation = true } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("清空日志")
                .disabled(store.entries.isEmpty)
            }
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height > 0 &&
                geometry.visibleRect.maxY >= geometry.contentSize.height - 80
        } action: { _, isNearBottom in
            guard isNearBottom, loadedCount < store.entries.count else { return }
            loadedCount = min(loadedCount + 100, store.entries.count)
        }
        .onAppear { store.setRetention(days: retentionDays) }
        .onChange(of: retentionDays) { _, _ in store.setRetention(days: retentionDays) }
        .alert("确定清空所有日志？", isPresented: $isShowingClearConfirmation) {
            Button("清空日志", role: .destructive) { store.clear() }
            Button("取消", role: .cancel) { }
        }
        .alert("导出失败", isPresented: $isShowingExportError) {
            Button("好", role: .cancel) { }
        } message: {
            Text("无法准备日志文件，请稍后重试。")
        }
        .background {
            RuntimeLogSharePresenter(file: shareFile) {
                shareFile = nil
            } onError: {
                shareFile = nil
                isShowingExportError = true
            }
            .frame(width: 0, height: 0)
        }
    }
}

private struct SharedLogFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Present directly from the current UIKit hierarchy, without a SwiftUI sheet.
private struct RuntimeLogSharePresenter: UIViewControllerRepresentable {
    let file: SharedLogFile?
    let onFinished: () -> Void
    let onError: () -> Void

    func makeUIViewController(context: Context) -> PresenterController { PresenterController() }

    func updateUIViewController(_ presenter: PresenterController, context: Context) {
        guard let file else { return }
        presenter.share(file.url, onFinished: onFinished, onError: onError)
    }

    final class PresenterController: UIViewController {
        private var isPresentingShare = false

        func share(_ url: URL, onFinished: @escaping () -> Void, onError: @escaping () -> Void) {
            guard !isPresentingShare else { return }
            isPresentingShare = true
            // Present after SwiftUI finishes this view update.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.view.window != nil else {
                    self.isPresentingShare = false
                    onError()
                    return
                }
                var top: UIViewController = self
                while let parent = top.parent { top = parent }
                while let presented = top.presentedViewController { top = presented }
                guard !top.isBeingDismissed, !top.isBeingPresented else {
                    self.isPresentingShare = false
                    onError()
                    return
                }
                let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                controller.completionWithItemsHandler = { [weak self] _, _, _, error in
                    Task { @MainActor in
                        self?.isPresentingShare = false
                        if error != nil { onError() } else { onFinished() }
                    }
                }
                if let popover = controller.popoverPresentationController {
                    popover.sourceView = top.view
                    popover.sourceRect = CGRect(x: top.view.bounds.maxX - 44,
                                                y: top.view.safeAreaInsets.top, width: 44, height: 44)
                }
                top.present(controller, animated: true)
            }
        }
    }
}

private struct AppearanceSettingsView: View {
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    @AppStorage("appearance.accent") private var accent = "vesper"
    @State private var confirmingAccentReset = false

    var body: some View {
        SettingsPage {
            Group {
                SettingsIntroCard(title: "外观设置", symbol: "paintpalette", description: "选择主题、颜色和应用图标。")

                SettingsSection {
                    SettingsPicker(selection: $appearanceMode) {
                        Text("跟随系统").tag("system")
                        Text("深色").tag("dark")
                        Text("浅色").tag("light")
                    } label: { Text("主题") }
                    .pickerStyle(.menu)
                    ColorPicker(selection: Binding(
                        get: { VesperTheme.accent(accent) },
                        set: { color in
                            if let identifier = VesperTheme.accentIdentifier(for: color) {
                                accent = identifier
                            }
                        }
                    ), supportsOpacity: false) { Text("主题色") }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    Button { confirmingAccentReset = true } label: {
                        Text("重置主题色")
                            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                        .disabled(accent == "vesper")
                } footer: {
                    Text("主题模式控制浅色或深色外观；主题色应用于选中状态和交互强调色。")
                }
                SettingsSection {
                    AppIconChoices()
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .background(VesperTheme.background)
        .alert("重置主题色？", isPresented: $confirmingAccentReset) {
            Button("重置主题色", role: .destructive) { accent = "vesper" }
            Button("取消", role: .cancel) { }
        }
    }
}


struct TabSettingsView: View {
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("navigation.defaultTab") private var defaultTab = "media"
    @AppStorage("navigation.tabBarCanMinimize") private var tabBarCanMinimize = true
    @State private var isShowingResetConfirmation = false
    @State private var isShowingOrderSettings = false

    private var sections: [AppSection] {
        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        return saved + AppSection.allCases.filter { !saved.contains($0) }
    }

    var body: some View {
        SettingsPage {
            Group {
                SettingsIntroCard(title: "标签设置", symbol: "rectangle.3.group", description: "调整标签排列顺序和显示状态。")

                SettingsSection {
                    ForEach(sections.filter { $0 != .settings }) { section in
                        Toggle(isOn: Binding(
                            get: { !hidden.split(separator: ",").contains(Substring(section.rawValue)) },
                            set: { visible in
                                var values = Set(hidden.split(separator: ",").map(String.init))
                                if visible { values.remove(section.rawValue) } else { values.insert(section.rawValue) }
                                hidden = values.sorted().joined(separator: ",")
                                if !visible && defaultTab == section.rawValue { defaultTab = "settings" }
                            }
                        )) { SettingsLabel(LocalizedStringKey(section.title), symbol: section.symbol) }
                    }
                } footer: {
                    Text("关闭后，该页面将从标签栏移除，可能没有其他访问入口。需要使用时，请在此重新开启。设置标签始终保留。")
                }
                SettingsSection {
                    Button { isShowingOrderSettings = true } label: {
                        SettingsLabel("标签顺序", symbol: "arrow.up.arrow.down")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    SettingsPicker("默认标签页", selection: $defaultTab) {
                        ForEach(sections.filter { $0 == .settings || !hidden.split(separator: ",").contains(Substring($0.rawValue)) }) { section in
                            Text(section.title).tag(section.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text("打开 App 时优先显示所选标签页；已关闭的标签不可设为默认。")
                }
                SettingsSection {
                    Toggle(isOn: $tabBarCanMinimize) {
                        SettingsLabel("允许标签栏收缩", symbol: "arrow.down.right.and.arrow.up.left")
                    }
                } footer: {
                    Text("关闭后，向下滚动页面时标签栏保持展开。")
                }

            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .background(VesperTheme.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("恢复默认", systemImage: "arrow.counterclockwise") {
                    isShowingResetConfirmation = true
                }
                .labelStyle(.iconOnly)
            }
        }
        .alert("恢复默认标签设置？", isPresented: $isShowingResetConfirmation) {
            Button("恢复默认", role: .destructive) {
                order = "media,sources,history,settings"
                hidden = ""
                defaultTab = "media"
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将恢复标签的排列顺序、显示状态和默认标签页。")
        }
        .sheet(isPresented: $isShowingOrderSettings) {
            NavigationStack {
                TabOrderSettingsView()
                    .navigationTitle("标签顺序")
                    .vesperNavigationStyle(.inline)
                    .toolbarRole(.automatic)
                    .navigationBarBackButtonHidden(true)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text("标签顺序").font(.headline)
                        }
                    }
            }
            .presentationDetents([.custom(TabOrderDetent.self)])
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(false)
            .presentationBackground(VesperTheme.background)
        }

    }

}


private struct TabOrderSettingsView: View {
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"

    private var sections: [AppSection] {
        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        return saved + AppSection.allCases.filter { !saved.contains($0) }
    }

    var body: some View {
        SettingsPage {
            SettingsSection {
                ForEach(sections) { section in
                    Label(section.title, systemImage: section.symbol)
                }
                .onMove { offsets, destination in
                    var updated = sections
                    updated.move(fromOffsets: offsets, toOffset: destination)
                    order = updated.map(\.rawValue).joined(separator: ",")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollDisabled(true)
    }
}

private struct TabOrderDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(context.maxDetentValue, context.dynamicTypeSize.isAccessibilitySize ? 540 : 360)
    }
}

/// Introductory card shared by secondary settings pages.
struct SettingsIntroCard: View {
    let title: LocalizedStringKey
    let symbol: String
    let description: LocalizedStringKey
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 28.0
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: iconSize)).foregroundStyle(.white)
                .frame(width: iconSize + 20, height: iconSize + 20)
                .background(.tint, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Text(description).foregroundStyle(.secondary).font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
    }
}

/// Match the standard symbol-and-text labels used by tab settings.
struct SettingsLabel: View {
    let title: LocalizedStringKey
    let symbol: String

    init(_ title: LocalizedStringKey, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(title)
                .font(.body)
                .foregroundStyle(Color(uiColor: .label))
        }
        .frame(minHeight: 28)
    }
}

/// Inline choices; the only available icon is the installed primary icon.
private struct AppIconChoices: View {
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            VStack(spacing: 8) {
                Image("VesperAppIcon")
                    .resizable()
                    .scaledToFit()
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14).stroke(.tint, lineWidth: 2)
                    }
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("默认图标")
            .accessibilityAddTraits(.isSelected)
        }
        .padding(.vertical, 8)
    }
}

private struct PlaybackLicensesView: View {
    private var notices: String {
        ["PlaybackNotices", "AetherEngine-LICENSE", "SwiftVLC-LICENSE"].compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }.joined(separator: "\n\n")
    }

    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "开源许可", symbol: "doc.plaintext", description: "查看第三方组件许可。")
            SettingsSection {
                Text(verbatim: notices)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        }
    }
}

/// A single native grouped List owns every row and section on a settings page.
struct SettingsPage<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        List { content }
            .listStyle(.insetGrouped)
            .listSectionSpacing(20)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}

struct SettingsSection<Rows: View, Footer: View>: View {
    private let title: LocalizedStringKey?
    private let rows: Rows
    private let footer: Footer
    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Rows, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.rows = content()
        self.footer = footer()
    }
    var body: some View {
        Section {
            rows
                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
        } header: {
            if let title { Text(title).textCase(nil) }
        } footer: { footer }
    }
}

extension SettingsSection where Footer == EmptyView {
    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Rows) {
        self.init(title, content: content, footer: { EmptyView() })
    }
}

/// Keep the selected value on one line and give it priority over the row label.
struct SettingsPicker<Selection: Hashable, Options: View, Label: View>: View {
    let selection: Binding<Selection>
    private let options: Options
    private let label: Label
    init(selection: Binding<Selection>, @ViewBuilder content: () -> Options, @ViewBuilder label: () -> Label) {
        self.selection = selection; self.options = content(); self.label = label()
    }
    var body: some View {
        HStack(spacing: 8) {
            label.lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            Picker(selection: selection) { options } label: { label }
                .labelsHidden().pickerStyle(.menu)
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }
}

extension SettingsPicker where Label == Text {
    init(_ title: LocalizedStringKey, selection: Binding<Selection>, @ViewBuilder content: () -> Options) {
        self.init(selection: selection, content: content, label: { Text(title) })
    }
}

private extension MediaLayoutSettings.Metric {
    var label: LocalizedStringKey {
        switch self {
        case .thumbnailHeight: "缩略图高度"
        case .groupSpacing: "媒体库分组上下间距"
        case .titlePadding: "媒体库分组标题上下间距"
        case .scrollPadding: "媒体库分组滚动区域上下间距"
        case .itemWidth: "媒体库分组项目宽度"
        case .itemHeight: "媒体库分组项目高度"
        case .itemVerticalPadding: "媒体库分组项目上下间距"
        case .itemSpacing: "媒体库分组项目左右间距"
        case .endPadding: "媒体库滚动区域左右内缩"
        case .episodeCardWidth: "剧集卡片宽度"
        case .episodeCardHeight: "剧集卡片高度"
        case .statusBarEdgeBlur: "状态栏边缘模糊最大强度"
        case .headerBackdropBlur: "Header 毛玻璃效果强度"
        case .headerForegroundBlur: "Header 模糊效果最大强度"
        case .headerAnimationMinimumDistance: "Header 触发动画最小移动距离"
        case .headerTitleSize: "Header 大标题字号"
        case .carouselBlurHeight: "底部模糊主体高度"
        case .carouselBlurFadeHeight: "上沿渐隐高度"
        case .carouselBlurStrength: "毛玻璃效果强度"
        }
    }
}

private struct DebugSettingsView: View {
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @AppStorage(ImageCacheDebugSettings.ignoreLocalCacheKey) private var ignoreLocalImageCache = false
    @AppStorage(EmbyUserAgentPolicy.enabledKey) private var enabled = false
    @AppStorage(EmbyUserAgentPolicy.nameKey) private var clientName = ""
    @AppStorage(EmbyUserAgentPolicy.versionKey) private var clientVersion = ""

    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "客户端模拟", symbol: "ladybug", description: "调整 Emby 请求中的客户端标识。")
            SettingsSection {
                Toggle("启用客户端模拟", isOn: $enabled)
                if enabled {
                    TextField("客户端名称", text: $clientName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("客户端版本", text: $clientVersion)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                LabeledContent("当前标识") {
                    Text(verbatim: "\(EmbyUserAgentPolicy.clientName)/\(EmbyUserAgentPolicy.clientVersion)")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("客户端名称和版本会同时用于 User-Agent 及 Emby Authorization 请求头。留空或关闭时使用 Vesper 默认值。")
            }
            SettingsSection("图片缓存") {
                Toggle("图片不使用本地缓存", isOn: $ignoreLocalImageCache)
            } footer: {
                Text("启用后，图片会直接从来源加载，且不会写入本地图片缓存。")
            }
            SettingsSection("界面设计") {
                ForEach(Self.interfaceMetrics, id: \.self) { metric in
                    layoutStepper(metric)
                }
                Button("恢复默认值", systemImage: "arrow.counterclockwise") {
                    layout.reset(Self.interfaceMetrics)
                }
            }
            SettingsSection("媒体页导航栏") {
                ForEach(Self.headerMetrics, id: \.self) { metric in
                    layoutStepper(metric)
                }
                Button("恢复默认值", systemImage: "arrow.counterclockwise") {
                    layout.reset(Self.headerMetrics)
                }
            }
            SettingsSection("轮播图底部模糊") {
                ForEach(Self.carouselBlurMetrics, id: \.self) { metric in
                    layoutStepper(metric)
                }
                Button("恢复默认值", systemImage: "arrow.counterclockwise") {
                    layout.reset(Self.carouselBlurMetrics)
                }
            }
        }
    }

    private static let headerMetrics: [MediaLayoutSettings.Metric] = [
        .statusBarEdgeBlur, .headerBackdropBlur, .headerForegroundBlur,
        .headerAnimationMinimumDistance, .headerTitleSize
    ]

    private static let carouselBlurMetrics: [MediaLayoutSettings.Metric] = [
        .carouselBlurHeight, .carouselBlurFadeHeight, .carouselBlurStrength
    ]

    private static let interfaceMetrics = MediaLayoutSettings.Metric.allCases.filter {
        !headerMetrics.contains($0) && !carouselBlurMetrics.contains($0)
    }

    private func layoutStepper(_ metric: MediaLayoutSettings.Metric) -> some View {
        let value = layout[metric]
        let displayValue: Text
        if metric == .thumbnailHeight && value == 0 {
            displayValue = Text("自动")
        } else if metric.usesPercent {
            displayValue = Text(Double(value) / 100, format: .percent)
        } else {
            displayValue = Text("\(value) pt")
        }
        return Stepper(value: Binding(get: { layout[metric] }, set: { layout[metric] = $0 }),
                       in: metric.range) {
            VStack(alignment: .leading, spacing: 3) {
                Text(metric.label)
                displayValue.font(.footnote).monospacedDigit().foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityLabel(Text(metric.label))
        .accessibilityValue(displayValue)
    }
}

private extension AppCacheCategory {
    var label: String {
        switch self {
        case .library: String(localized: "媒体库信息")
        case .images: String(localized: "图片")
        case .videos: String(localized: "视频")
        case .subtitles: String(localized: "字幕")
        case .danmaku: String(localized: "弹幕")
        case .other: String(localized: "其他")
        }
    }

    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .images: "photo"
        case .videos: "film"
        case .subtitles: "captions.bubble"
        case .danmaku: "text.bubble"
        case .other: "archivebox"
        }
    }
}

private struct CacheManagementView: View {
    @State private var sizes: [AppCacheCategory: Int64] = [:]
    @State private var selecting = false
    @State private var selected: Set<AppCacheCategory> = []
    @State private var confirmation: Set<AppCacheCategory> = []
    @State private var showsConfirmation = false
    @State private var clearing = false
    @State private var failed: [String] = []
    @State private var showsFailure = false

    private var categoriesToClear: Set<AppCacheCategory> {
        selecting ? selected : Set(AppCacheCategory.allCases)
    }

    var body: some View {
        CacheCategoryList(sizes: sizes, selecting: $selecting, selected: $selected, clearing: clearing)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .accessibilityAction(named: Text("选择缓存类别")) {
                if !clearing { selecting = true }
            }
            .navigationBarBackButtonHidden(selecting)
            .toolbar {
                if selecting {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button("完成", systemImage: "checkmark") {
                            selecting = false
                            selected.removeAll()
                        }
                        .labelStyle(.iconOnly)
                        Button("全选") { selected = Set(AppCacheCategory.allCases) }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清理") {
                        confirmation = categoriesToClear
                        showsConfirmation = true
                    }
                    .disabled(clearing || categoriesToClear.isEmpty)
                }
            }
            .alert(selecting ? "清理选中的缓存？" : "清理所有缓存？", isPresented: $showsConfirmation) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) {
                    let categories = confirmation
                    clearing = true
                    Task {
                        let cache = AppCacheStore.shared
                        let failures = await cache.clear(categories)
                        sizes = await cache.sizes()
                        selected.subtract(categories.subtracting(failures))
                        failed = AppCacheCategory.allCases.filter { failures.contains($0) }.map(\.label)
                        clearing = false
                        showsFailure = !failed.isEmpty
                    }
                }
            }
            .alert("部分缓存无法清理", isPresented: $showsFailure) {
                Button("好", role: .cancel) {}
            } message: {
                Text(verbatim: failed.joined(separator: "、"))
            }
            .task { sizes = await AppCacheStore.shared.sizes() }
    }
}

private struct CacheCategoryList: UIViewRepresentable {
    let sizes: [AppCacheCategory: Int64]
    @Binding var selecting: Bool
    @Binding var selected: Set<AppCacheCategory>
    let clearing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITableView {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.allowsSelectionDuringEditing = true
        table.allowsMultipleSelectionDuringEditing = true
        table.estimatedRowHeight = 52
        table.rowHeight = UITableView.automaticDimension
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        return table
    }

    func updateUIView(_ table: UITableView, context: Context) {
        let coordinator = context.coordinator
        let changedSizes = coordinator.view.sizes != sizes
        coordinator.view = self
        table.isUserInteractionEnabled = !clearing
        if table.isEditing != selecting { table.setEditing(selecting, animated: true) }
        if changedSizes { table.reloadData() }
        let selectedRows = Set(table.indexPathsForSelectedRows ?? [])
        let desiredRows = Set(AppCacheCategory.allCases.enumerated().compactMap { index, category in
            selecting && selected.contains(category) ? IndexPath(row: index, section: 0) : nil
        })
        for row in selectedRows.subtracting(desiredRows) { table.deselectRow(at: row, animated: false) }
        for row in desiredRows.subtracting(selectedRows) { table.selectRow(at: row, animated: false, scrollPosition: .none) }
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        var view: CacheCategoryList
        init(_ view: CacheCategoryList) { self.view = view }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            AppCacheCategory.allCases.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let category = AppCacheCategory.allCases[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "CacheCategory")
                ?? UITableViewCell(style: .value1, reuseIdentifier: "CacheCategory")
            var content = UIListContentConfiguration.valueCell()
            content.image = UIImage(systemName: category.symbol)
            content.imageProperties.tintColor = tableView.tintColor
            content.text = category.label
            content.secondaryText = view.sizes[category].map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "—"
            cell.contentConfiguration = content
            return cell
        }

        func tableView(_ tableView: UITableView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
            !view.clearing
        }

        func tableView(_ tableView: UITableView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
            tableView.setEditing(true, animated: true)
            view.selecting = true
        }

        func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
            tableView.isEditing ? indexPath : nil
        }

        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            view.selected.insert(AppCacheCategory.allCases[indexPath.row])
        }

        func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
            view.selected.remove(AppCacheCategory.allCases[indexPath.row])
        }

        func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
            .none
        }
    }
}
