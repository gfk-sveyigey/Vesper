import SwiftUI
import UIKit
import Photos
import LocalAuthentication

private enum SettingsRoute: Hashable {
    case tabs, appearance, logs, licenses, gestures, playback, subtitles, danmaku, debug, cache, emby, permissions, appLock

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
        case .appLock: "密码保护"
        }
    }
}

private struct AppLockSettingsView: View {
    @EnvironmentObject private var appLock: AppLock
    @AppStorage(AppLock.enabledKey) private var enabled = false
    @AppStorage(AppLock.biometricEnabledKey) private var biometricEnabled = false
    @AppStorage(AppLock.biometricPriorityKey) private var biometricPriority = false
    @AppStorage(AppLock.scopeKey) private var scope = "launch"
    @AppStorage(AppLock.timeoutKey) private var timeout = 0.0
    @AppStorage(AppLock.blurKey) private var backgroundBlur = true
    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "密码保护", symbol: "lock",
                              description: "使用设备密码保护 Vesper，并控制重新验证与后台隐私显示。")
            SettingsSection {
                Toggle("密码保护", isOn: Binding(get: { enabled }, set: changeEnabled))
                if enabled {
                    Button("重置密码", systemImage: "key") { appLock.requestAuthentication(.resetPassword) }
                    Toggle("启用生物识别", isOn: $biometricEnabled)
                        .disabled(!biometricAvailable)
                    Toggle("优先使用生物识别", isOn: $biometricPriority)
                        .disabled(!biometricEnabled || !biometricAvailable)
                }
            }
            if enabled {
                SettingsSection("密码保护范围") {
                    SettingsPicker("保护范围", selection: $scope) {
                        Text("App 启动").tag("launch")
                        Text("媒体来源").tag("source")
                        Text("App 启动和媒体来源").tag("both")
                    }
                    SettingsPicker("重新验证时间", selection: $timeout) {
                        Text("立即").tag(0.0)
                        Text("1 分钟").tag(60.0)
                        Text("5 分钟").tag(300.0)
                        Text("15 分钟").tag(900.0)
                    }
                    Toggle("后台高斯模糊", isOn: $backgroundBlur)
                }
            }
        }
        .onAppear { appLock.settingsVisibleProvider = { true } }
        .onDisappear {
            appLock.settingsVisibleProvider = { false }
            appLock.revokeSettingsAuthorization()
        }
        .onChange(of: biometricEnabled) { _, value in
            if !value { biometricPriority = false }
        }
        .onChange(of: backgroundBlur) { _, value in appLock.setBackgroundBlur(value) }
    }

    private var biometricAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private func changeEnabled(_ value: Bool) {
        guard !value else {
            appLock.requestAuthentication(.createPassword)
            return
        }
        appLock.requestAuthentication(.disableProtection)
    }

}

struct AppLockScreen: View {
    @EnvironmentObject private var appLock: AppLock
    @AppStorage(AppLock.biometricEnabledKey) private var biometricEnabled = false
    @AppStorage(AppLock.biometricPriorityKey) private var biometricPriority = false
    @State private var pin = ""
    @State private var errorMessage: String?
    @State private var isAuthenticating = false
    @State private var failures = 0
    @State private var showPassword = false
    @State private var biometricType = AppLock.shared.biometricType
    @State private var automaticAttemptPurpose: AppLock.AuthenticationPurpose?

    private var passwordOnly: Bool {
        [.createPassword, .resetPassword, .disableProtection].contains(appLock.authenticationRequest)
    }
    private var displaysPassword: Bool {
        passwordOnly || !biometricEnabled || !biometricPriority || showPassword || biometricType == .none
    }
    private var passwordPrompt: String {
        switch appLock.authenticationRequest {
        case .createPassword: "设置六位数字密码"
        case .resetPassword: "输入旧密码以重置"
        case .disableProtection: "输入密码以关闭保护"
        default: "输入密码以继续"
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: displaysPassword ? "lock.fill" : biometricType.symbol)
                .font(.system(size: 42)).foregroundStyle(.secondary)
            if displaysPassword {
                Text(passwordPrompt).font(.title3.weight(.semibold))
                SecureField("六位数字密码", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.title2.monospacedDigit())
                    .onChange(of: pin) { _, value in
                        pin = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                        if pin.count == 6 {
                            if appLock.authenticationRequest == .createPassword { saveNewPassword() }
                            else { unlockWithPassword() }
                        }
                    }
                if let errorMessage { Text(verbatim: errorMessage).foregroundStyle(.red).font(.footnote) }
            } else if failures == 0 {
                Text(verbatim: String(format: VesperLocalization.string("需要 %@"), biometricType.title))
            }
            if !passwordOnly, biometricEnabled, biometricType != .none, failures < 2,
               !(biometricPriority && failures == 0), !appLock.isBiometricAuthenticationInProgress {
                Button {
                    Task { await authenticate() }
                } label: {
                    Label {
                        Text(verbatim: String(format: VesperLocalization.string(failures == 0 ? "使用 %@" : "再次尝试 %@"), biometricType.title))
                    } icon: { Image(systemName: biometricType.symbol) }
                }
                .disabled(isAuthenticating)
            }
            if appLock.authenticationRequest != .appUnlock && appLock.authenticationRequest != .settingsAccess {
                Button("取消", systemImage: "xmark") { appLock.cancelAuthentication() }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.regularMaterial).ignoresSafeArea() }
        .contentShape(Rectangle())
        .task(id: appLock.authenticationRequest) {
            pin = ""
            errorMessage = nil
            failures = 0
            showPassword = false
            biometricType = appLock.biometricType
            if !passwordOnly, biometricEnabled, biometricPriority, biometricType != .none {
                if automaticAttemptPurpose != appLock.authenticationRequest {
                    automaticAttemptPurpose = appLock.authenticationRequest
                    await authenticate()
                }
            } else if appLock.authenticationRequest == nil {
                automaticAttemptPurpose = nil
            }
        }
    }

    private func finish() {
        guard let purpose = appLock.authenticationRequest else { return }
        appLock.didAuthenticate(purpose)
    }

    private func unlockWithPassword() {
        if appLock.verify(pin) {
            switch appLock.authenticationRequest {
            case .resetPassword:
                appLock.requestAuthentication(.createPassword)
            case .disableProtection:
                appLock.didAuthenticate(.disableProtection)
                biometricEnabled = false
                biometricPriority = false
                appLock.removePassword()
                UserDefaults.standard.set(false, forKey: AppLock.enabledKey)
                appLock.activate()
            default: finish()
            }
        }
        else {
            pin = ""
            errorMessage = VesperLocalization.string("密码错误，请重试。")
        }
    }

    private func saveNewPassword() {
        do {
            try appLock.setPassword(pin)
            UserDefaults.standard.set(true, forKey: AppLock.enabledKey)
            biometricEnabled = false
            biometricPriority = false
            finish()
        } catch {
            pin = ""
            errorMessage = error.localizedDescription
        }
    }

    private func authenticate() async {
        guard !isAuthenticating, !appLock.isBiometricAuthenticationInProgress else { return }
        let purpose = appLock.authenticationRequest
        isAuthenticating = true
        let success = await appLock.authenticateBiometrically(reason: biometricReason)
        isAuthenticating = false
        guard !Task.isCancelled, appLock.authenticationRequest == purpose else { return }
        if success { finish() }
        else {
            failures += 1
            if failures >= 2 { showPassword = true }
        }
    }

    private var biometricReason: String {
        switch appLock.authenticationRequest {
        case .sourcePrivacy: "进入来源隐私模式"
        case .settingsAccess: "访问密码保护设置"
        case .resetPassword, .disableProtection, .createPassword: "验证密码保护"
        default: "解锁 Vesper"
        }
    }
}

@MainActor
private final class DebugSettingsVisibility: ObservableObject {
    static let shared = DebugSettingsVisibility()
    @Published var isRevealed = false
}

struct SettingsView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject private var appLock: AppLock
    @EnvironmentObject private var playback: PlaybackSession
    @AppStorage("language.code") private var languageCode = "system"
    @ObservedObject private var debugVisibility = DebugSettingsVisibility.shared

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VesperRootScrollView(title: "设置") {
            VStack(alignment: .leading, spacing: 32) {
                settingsGroup {
                    settingsLink(.permissions, title: "应用权限", symbol: "hand.raised")
                    Divider().padding(.leading, 52)
                    settingsLink(.appLock, title: "密码保护", symbol: "lock")
                    Divider().padding(.leading, 52)
                    settingsLink(.appearance, title: "外观设置", symbol: "paintpalette")
                    Divider().padding(.leading, 52)
                    settingsLink(.tabs, title: "标签设置", symbol: "rectangle.3.group")
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
                settingsGroup {
                    settingsLink(.playback, title: "播放设置", symbol: "play.circle")
                    Divider().padding(.leading, 52)
                    settingsLink(.gestures, title: "播放手势", symbol: "hand.draw")
                    Divider().padding(.leading, 52)
                    settingsLink(.subtitles, title: "字幕设置", symbol: "captions.bubble")
                    Divider().padding(.leading, 52)
                    settingsLink(.danmaku, title: "弹幕设置", symbol: "text.bubble")
                }
                settingsGroup {
                    settingsLink(.emby, title: "Emby 设置", symbol: "server.rack")
                    Divider().padding(.leading, 52)
                    settingsLink(.cache, title: "缓存管理", symbol: "internaldrive")
                }
                settingsGroup {
                    settingsLink(.logs, title: "运行日志", symbol: "doc.text")
                    Divider().padding(.leading, 52)
                    settingsLink(.licenses, title: "开源许可", symbol: "doc.plaintext")
                }
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
                case .appLock: AppLockSettingsView()
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

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
    }

    @ViewBuilder
    private func settingsLink(_ route: SettingsRoute, title: LocalizedStringKey, symbol: String) -> some View {
        if route == .appLock {
            Button {
                if appLock.isEnabled {
                    appLock.requestAuthentication(.settingsAccess) { path.append(route) }
                } else { path.append(route) }
            } label: { settingsLinkLabel(title, symbol: symbol) }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: route) { settingsLinkLabel(title, symbol: symbol) }
                .buttonStyle(.plain)
        }
    }

    private func settingsLinkLabel(_ title: LocalizedStringKey, symbol: String) -> some View {
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

}

private struct EmbySettingsView: View {
    @ObservedObject private var trakt = TraktAccountStore.shared
    @State private var showsTraktAccount = false
    @State private var showsProgressPriority = false
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
            SettingsIntroCard(title: "Emby 设置", symbol: "server.rack", description: "连接 Trakt，设置续播进度优先级、片头片尾跳过、下一集预加载与音频字幕偏好。")
            SettingsSection("观看记录") {
                Button {
                    if trakt.isConnected { showsTraktAccount = true } else { trakt.connect() }
                } label: {
                    HStack(spacing: 12) {
                        Text(verbatim: "Trakt").font(.body)
                            .foregroundStyle(Color(uiColor: .label))
                        Spacer()
                        if trakt.isConnecting { ProgressView() }
                        else if trakt.isConnected { Text("已连接").foregroundStyle(.secondary) }
                        else { Text("未连接").foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(trakt.isConnecting)
                Button {
                    showsProgressPriority = true
                } label: {
                    HStack {
                        Text("播放进度优先级")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
            }
            SettingsSection("音频与字幕") {
                SettingsPicker("默认音轨语言", selection: $audioLanguage) {
                    ForEach(EmbyTrackPreferences.languages.indices, id: \.self) { index in
                        Text(LocalizedStringKey(EmbyTrackPreferences.languages[index].1))
                            .tag(EmbyTrackPreferences.languages[index].0)
                    }
                }
                SettingsPicker("默认字幕语言", selection: $subtitleLanguage) {
                    ForEach(EmbyTrackPreferences.languages.indices, id: \.self) { index in
                        Text(LocalizedStringKey(EmbyTrackPreferences.languages[index].1))
                            .tag(EmbyTrackPreferences.languages[index].0)
                    }
                }
                Toggle("无对应语言时关闭字幕", isOn: $disableMissingSubtitle)
            }
            SettingsSection("跳过片头片尾") {
                Toggle("自动跳过片头", isOn: $skipIntro)
                Toggle("自动跳过片尾", isOn: $skipOutro)
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
                SettingsPicker("Wi-Fi", selection: $wifiCacheMB) {
                    ForEach(EmbyPreloadCacheSettings.choices, id: \.self) { size in
                        Text("\(size) MB").tag(size)
                    }
                }
                SettingsPicker("蜂窝网络", selection: $cellularCacheMB) {
                    ForEach(EmbyPreloadCacheSettings.choices, id: \.self) { size in
                        Text("\(size) MB").tag(size)
                    }
                }
                Text("每次打开 Emby 视频时按当前网络应用。Aether 按容量限制支持的临时媒体缓存；VLC 按视频总码率换算缓冲时长，最长 60 秒。不是流量上限或播放器总内存限制；Aether 原生远程 HLS 暂不支持按容量限制。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            SettingsSection("浏览显示") {
                NavigationLink("图标库") { EmbyIconLibrarySettingsView() }
                Toggle("完整加载后渲染", isOn: $waitsForArtwork)
            }
        }
        .alert("连接失败", isPresented: Binding(get: { trakt.errorMessage != nil }, set: { if !$0 { trakt.errorMessage = nil } })) {
            Button("好", role: .cancel) { trakt.errorMessage = nil }
        } message: {
            Text(trakt.errorMessage ?? "")
        }
        .sheet(isPresented: $showsTraktAccount) { TraktAccountSheet() }
        .sheet(isPresented: $showsProgressPriority) { EmbyProgressPrioritySheet() }
        .sheet(isPresented: $showsSkipDatabases) { EmbySkipDatabasesView() }
        .task {
            if ["zho", "chi", "zh"].contains(audioLanguage) { audioLanguage = "zh-Hans" }
            if ["zho", "chi", "zh"].contains(subtitleLanguage) { subtitleLanguage = "zh-Hans" }
        }
    }
}

private struct TraktAccountSheet: View {
    @ObservedObject private var trakt = TraktAccountStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var overview: TraktAccountOverview?
    @State private var failure: String?
    @State private var loading = true
    @State private var requestID = UUID()
    @State private var height: CGFloat = 320
    @State private var confirmsDisconnect = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let overview {
                    profile(overview.user)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        statistic("观看电影", value: overview.statistics.map { $0.movies.watched.formatted() })
                        statistic("观看剧集", value: overview.statistics.map { $0.shows.watched.formatted() })
                        statistic("观看集数", value: overview.statistics.map { $0.episodes.watched.formatted() })
                        statistic("观看时长", value: overview.statistics.map { watchTime($0.watchedMinutes) })
                    }
                    if overview.statistics == nil {
                        Text("Trakt 暂未提供此账号的观看统计。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                } else if let failure {
                    Text(failure).font(.callout).foregroundStyle(.secondary)
                    Button("重试") { requestID = UUID() }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(height)])
        .presentationDragIndicator(.hidden)
        .confirmationDialog("断开 Trakt 连接？", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("断开连接", role: .destructive) { trakt.disconnect(); dismiss() }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: trakt.isConnected) { _, connected in if !connected { dismiss() } }
        .task(id: requestID) {
            loading = true
            failure = nil
            do { overview = try await trakt.accountOverview() }
            catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                failure = String(localized: "无法加载 Trakt 账号信息，请稍后重试。")
            }
            loading = false
        }
    }

    private func profile(_ user: TraktAccountUser) -> some View {
        VStack(spacing: 8) {
            AsyncImage(url: user.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().foregroundStyle(.secondary)
            }
            .frame(width: 80, height: 80).clipShape(Circle())
            .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text(verbatim: user.displayName).font(.title2.bold())
                if user.isVIP {
                    Text(verbatim: "VIP").font(.caption.bold())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
                Button {
                    confirmsDisconnect = true
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.body)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("断开连接")
            }
            Text(verbatim: "@" + user.username).font(.subheadline).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    private func statistic(_ title: LocalizedStringKey, value: String?) -> some View {
        VStack(spacing: 8) {
            Text(value ?? "—").font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 84)
        .padding(8)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func watchTime(_ minutes: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .short
        return formatter.string(from: TimeInterval(minutes) * 60) ?? "—"
    }
}

private struct EmbySkipDatabasesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var databases = EmbySkipSettings.databases
    @State private var editing: EmbySkipDatabase?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            SettingsPage {

                SettingsSection {
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
                SettingsSection {
                    Button("添加数据库", systemImage: "plus") { adding = true }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("片头片尾数据库")
            .vesperNavigationStyle(.inline)
            .toolbarRole(.automatic)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("片头片尾数据库").font(.headline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("完成")
                        .tint(nil)
                }
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
        .presentationDetents([.custom(TabOrderDetent.self), .large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(VesperTheme.background)
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
                SettingsPicker("数据库格式", selection: $database.format) {
                    ForEach(EmbySkipDatabase.Format.allCases) { Text($0.title).tag($0) }
                }
                Text("IntroDB 填写 /segments 之前的地址；TheIntroDB 可填写服务根地址或含 /v4 的地址。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("数据库设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("取消")
                        .tint(nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        database.name = database.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        database.address = database.address.trimmingCharacters(in: .whitespacesAndNewlines)
                        save(database); dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("保存")
                    .tint(nil)
                    .disabled(!valid || database.isBuiltin)
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
            SettingsIntroCard(title: "应用权限", symbol: "hand.raised", description: "查看照片访问权限，了解本地网络访问方式，并前往系统设置管理授权。")
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
                LabeledContent("本地网络", value: VesperLocalization.string("使用时由系统请求"))
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
        case .authorized: VesperLocalization.string("已允许")
        case .limited: VesperLocalization.string("受限访问")
        case .denied: VesperLocalization.string("未允许")
        case .restricted: VesperLocalization.string("受系统限制")
        case .notDetermined: VesperLocalization.string("尚未请求")
        @unknown default: VesperLocalization.string("未知")
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
                SettingsIntroCard(title: "运行日志", symbol: "doc.text", description: "查看运行日志、设置保留时间，导出或清空日志以便排查问题。")

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
                .tint(nil)
                .disabled(store.entries.isEmpty)
                Button(role: .destructive) { isShowingClearConfirmation = true } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("清空日志")
                .tint(nil)
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
                SettingsIntroCard(title: "外观设置", symbol: "paintpalette", description: "选择深浅色外观、主题色和应用图标，打造喜欢的界面。")

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
                SettingsIntroCard(title: "标签设置", symbol: "rectangle.3.group", description: "选择显示的标签页，调整排列顺序、默认页面和标签栏收缩方式。")

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
                    Toggle(isOn: $tabBarCanMinimize) {
                        SettingsLabel("允许标签栏收缩", symbol: "arrow.down.right.and.arrow.up.left")
                    }
                } footer: {
                    Text("关闭后，向下滚动页面时标签栏保持展开。")
                }
                SettingsSection {
                    Button { isShowingOrderSettings = true } label: {
                        Text("标签顺序")
                            .foregroundStyle(.tint)
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
                .tint(nil)
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

private struct EmbyProgressPrioritySheet: View {
    @AppStorage(EmbyProgressPriority.key) private var order = EmbyProgressPriority.defaultOrder

    var body: some View {
        NavigationStack {
            SettingsPage {
                SettingsSection {
                    ForEach(EmbyProgressPriority.order(order)) { source in
                        Text(LocalizedStringKey(source.titleKey))
                    }
                    .onMove { offsets, destination in
                        var updated = EmbyProgressPriority.order(order)
                        updated.move(fromOffsets: offsets, toOffset: destination)
                        order = updated.map(\.rawValue).joined(separator: ",")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollDisabled(true)
            .navigationTitle("播放进度优先级")
            .vesperNavigationStyle(.inline)
            .toolbarRole(.automatic)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("播放进度优先级").font(.headline)
                }
            }
        }
        .presentationDetents([.custom(TabOrderDetent.self)])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(false)
        .presentationBackground(VesperTheme.background)
    }
}

private struct TabOrderDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(context.maxDetentValue, context.dynamicTypeSize.isAccessibilitySize ? 540 : 360)
    }
}

// Navigation destinations can also inherit SwiftUI's isPresented = true.
// Mark actual sheet entry points explicitly instead of using it to infer a sheet.
private struct SettingsIntroCardsHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsIntroCardsHidden: Bool {
        get { self[SettingsIntroCardsHiddenKey.self] }
        set { self[SettingsIntroCardsHiddenKey.self] = newValue }
    }
}

/// Introductory card shared by secondary settings pages.
struct SettingsIntroCard: View {
    @Environment(\.settingsIntroCardsHidden) private var introCardsHidden
    let title: LocalizedStringKey
    let symbol: String
    let description: LocalizedStringKey
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 28.0
    var body: some View {
        if !introCardsHidden {
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
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
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
    @State private var selectedDocument: LicenseDocument?

    private let documents = [
        LicenseDocument(title: VesperLocalization.string("播放框架与依赖声明"), resource: "PlaybackNotices"),
        LicenseDocument(title: "AetherEngine", resource: "AetherEngine-LICENSE"),
        LicenseDocument(title: "SwiftVLC", resource: "SwiftVLC-LICENSE")
    ]

    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "开源许可", symbol: "doc.plaintext", description: "了解应用使用的开源组件，查看各项目的许可与声明。")
            SettingsSection {
                ForEach(documents) { document in
                    Button {
                        selectedDocument = document
                    } label: {
                        HStack(spacing: 12) {
                            Text(document.title)
                                .foregroundStyle(Color(uiColor: .label))
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: $selectedDocument) { document in
            LicenseDocumentSheet(document: document)
        }
    }
}

private struct LicenseDocument: Identifiable {
    let title: String
    let resource: String
    var id: String { resource }
    var contents: String {
        Bundle.main.url(forResource: resource, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? VesperLocalization.string("许可内容暂不可用。")
    }
}

private struct LicenseDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: LicenseDocument

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: document.contents)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Keep long setting titles readable without moving their controls below them.
private struct SettingsWrappingToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
        }
    }
}

private struct SettingsWrappingLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            configuration.content
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
    }
}

/// A single native grouped List owns every row and section on a settings page.
struct SettingsPage<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        List { content }
            .lineLimit(nil)
            .minimumScaleFactor(1)
            .toggleStyle(SettingsWrappingToggleStyle())
            .labeledContentStyle(SettingsWrappingLabeledContentStyle())
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
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
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
        HStack(alignment: .center, spacing: 8) {
            label.lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
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
        case .browserListTop: "媒体库列表上边距"
        case .browserListLeading: "媒体库列表左边距"
        case .browserListBottom: "媒体库列表下边距"
        case .browserListTrailing: "媒体库列表右边距"
        case .browserListRowHeight: "媒体库列表布局行高"
        case .browserListImageTop: "列表布局图片上间距"
        case .browserListImageLeading: "列表布局图片左间距"
        case .browserListImageBottom: "列表布局图片下间距"
        case .browserListImageTrailing: "列表布局图片右间距"
        case .sourceListRowHeight: "来源列表行高"
        case .sourceListIconTop: "来源图标上间距"
        case .sourceListIconLeading: "来源图标左间距"
        case .sourceListIconBottom: "来源图标下间距"
        case .sourceListIconTrailing: "来源图标右间距"
        case .mediaHeaderHeight: "Header 固定内容高度"
        case .mediaGlassStrength: "Header 下层毛玻璃强度"
        case .mediaGlassTint: "Header 毛玻璃颜色叠加强度"
        case .mediaGlassBorderWidth: "毛玻璃底边框宽度"
        case .mediaGlassBorderBlur: "毛玻璃底边框模糊强度"
        case .mediaGlassBorderOpacity: "毛玻璃底边框不透明度"
        case .mediaContentBlur: "Header 自身最大模糊"
        case .mediaContentBlurCurve: "Header 自身模糊曲线"
        case .mediaContentOpacityCurve: "Header 自身透明度曲线"
        case .mediaSnapThreshold: "Header 展开吸附阈值"
        case .mediaSnapCollapsedThreshold: "Header 收起吸附阈值"
        case .mediaSnapConflict: "Header 吸附冲突处理"
        case .mediaSnapDuration: "Header 吸附动画时长"
        case .mediaSnapCurve: "Header 吸附动画曲线"
        case .mediaEdgeTopStrength: "顶部边缘模糊顶端强度最小值"
        case .mediaEdgeTopMaxStrength: "顶部边缘模糊顶端强度最大值"
        case .mediaEdgeHeightCurve: "顶部边缘模糊高度曲线"
        case .mediaEdgeBottomStrength: "顶部边缘模糊底端强度"
        case .mediaEdgeTint: "顶部边缘模糊颜色叠加强度"
        case .mediaEdgeCurve: "顶部边缘模糊曲线"
        case .carouselBlurHeight: "底部模糊主体高度"
        case .carouselBlurFadeHeight: "上沿渐隐高度"
        case .carouselBlurStrength: "毛玻璃效果强度"
        case .carouselBlurTint: "轮播图底部颜色叠加强度"
        }
    }
}

private struct DebugSettingsSection<Rows: View, Footer: View>: View {
    let title: LocalizedStringKey
    let rows: Rows
    let footer: Footer
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    init(title: LocalizedStringKey, @ViewBuilder rows: () -> Rows, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.rows = rows()
        self.footer = footer()
    }

    var body: some View {
        SettingsSection {
            Button {
                withAnimation(reduceMotion ? nil : .default) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(title).fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            if isExpanded { rows }
        } footer: {
            if isExpanded { footer }
        }
    }
}

private extension DebugSettingsSection where Footer == EmptyView {
    init(title: LocalizedStringKey, @ViewBuilder rows: () -> Rows) {
        self.init(title: title, rows: rows, footer: { EmptyView() })
    }
}

private struct DebugSettingsView: View {
    @AppStorage("debug.mediaHeader.lightTint") private var lightTint = "#FFFFFF"
    @AppStorage("debug.mediaHeader.darkTint") private var darkTint = "#000000"
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @AppStorage(ImageCacheDebugSettings.ignoreLocalCacheKey) private var ignoreLocalImageCache = false
    @AppStorage(EmbyUserAgentPolicy.enabledKey) private var enabled = false
    @AppStorage(EmbyUserAgentPolicy.nameKey) private var clientName = ""
    @AppStorage(EmbyUserAgentPolicy.versionKey) private var clientVersion = ""
    @AppStorage(PlaybackDiagnostics.detachHiddenVideoSurfaceKey) private var detachHiddenVideoSurface = false
    @AppStorage(PlaybackDiagnostics.throttleHiddenPausedPollingKey) private var throttleHiddenPausedPolling = false

    var body: some View {
        SettingsPage {
            SettingsIntroCard(title: "调试功能", symbol: "ladybug", description: "调试 Emby 客户端标识、图片缓存与界面布局，微调导航栏和模糊效果。")
            DebugSettingsSection(title: "客户端模拟") {
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
            DebugSettingsSection(title: "图片缓存") {
                Toggle("图片不使用本地缓存", isOn: $ignoreLocalImageCache)
            } footer: {
                Text("启用后，图片会直接从来源加载，且不会写入本地图片缓存。")
            }
            DebugSettingsSection(title: "播放刷新率排查") {
                Toggle("隐藏播放器时卸载视频画面", isOn: $detachHiddenVideoSurface)
                Toggle("隐藏且暂停时将状态轮询降至 1 Hz", isOn: $throttleHiddenPausedPolling)
            } footer: {
                Text("一次只开启一个开关并观察 App 刷新率。前者临时移除窗口中的视频渲染视图；后者只在播放器隐藏且暂停时降低状态轮询频率。")
            }
            DebugSettingsSection(title: "界面设计") {
                ForEach(Self.interfaceMetrics, id: \.self) { metric in
                    layoutStepper(metric)
                }
                Button("恢复默认值", systemImage: "arrow.counterclockwise") {
                    layout.reset(Self.interfaceMetrics)
                }
            }
            DebugSettingsSection(title: "媒体页导航栏") {
                ForEach(Self.headerMetrics, id: \.self) { metric in
                    if metric == .mediaSnapConflict {
                        SettingsPicker(metric.label, selection: Binding(
                            get: { layout[metric] }, set: { layout[metric] = $0 }
                        )) {
                            Text("根据滚动方向").tag(0)
                            Text("根据距离").tag(1)
                        }
                    } else if metric == .mediaEdgeCurve || metric == .mediaEdgeHeightCurve || metric == .mediaContentOpacityCurve || metric == .mediaContentBlurCurve || metric == .mediaSnapCurve {
                        SettingsPicker(metric.label, selection: Binding(
                            get: { layout[metric] }, set: { layout[metric] = $0 }
                        )) {
                            Text("线性").tag(0)
                            Text("缓入缓出").tag(1)
                            Text("缓入").tag(2)
                            Text("缓出").tag(3)
                            Text("平滑阶梯").tag(4)
                        }
                    } else {
                        layoutStepper(metric)
                    }
                }
                Button("恢复默认值", systemImage: "arrow.counterclockwise") {
                    layout.reset(Self.headerMetrics)
                }
            }
            DebugSettingsSection(title: "轮播图底部模糊") {
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
        .mediaHeaderHeight, .mediaGlassStrength, .mediaGlassTint,
        .mediaGlassBorderWidth, .mediaGlassBorderBlur, .mediaGlassBorderOpacity, .mediaContentBlur,
        .mediaContentBlurCurve, .mediaContentOpacityCurve,
        .mediaSnapThreshold, .mediaSnapCollapsedThreshold, .mediaSnapConflict, .mediaSnapDuration, .mediaSnapCurve,
        .mediaEdgeTopStrength, .mediaEdgeTopMaxStrength, .mediaEdgeHeightCurve,
        .mediaEdgeBottomStrength, .mediaEdgeTint, .mediaEdgeCurve
    ]

    private static let carouselBlurMetrics: [MediaLayoutSettings.Metric] = [
        .carouselBlurHeight, .carouselBlurFadeHeight, .carouselBlurStrength, .carouselBlurTint
    ]

    private static let interfaceMetrics = MediaLayoutSettings.Metric.allCases.filter {
        !headerMetrics.contains($0) && !carouselBlurMetrics.contains($0)
    }

    private func layoutStepper(_ metric: MediaLayoutSettings.Metric) -> some View {
        let value = layout[metric]
        let displayValue: Text
        if metric == .thumbnailHeight && value == 0 {
            displayValue = Text("自动")
        } else if metric == .mediaGlassBorderWidth {
            let width = Double(layout.mediaGlassBorderWidth)
            displayValue = Text("\(width, format: .number.precision(.fractionLength(2))) pt")
        } else if metric == .mediaSnapDuration {
            displayValue = Text("\(value) ms")
        } else if metric.usesPercent || metric == .mediaSnapThreshold || metric == .mediaSnapCollapsedThreshold {
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
        case .library: VesperLocalization.string("媒体库信息")
        case .images: VesperLocalization.string("图片")
        case .videos: VesperLocalization.string("视频")
        case .subtitles: VesperLocalization.string("字幕")
        case .danmaku: VesperLocalization.string("弹幕")
        case .other: VesperLocalization.string("其他")
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
                        Button {
                            selecting = false
                            selected.removeAll()
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .accessibilityLabel("完成")
                        .tint(nil)
                        Button { selected = Set(AppCacheCategory.allCases) } label: {
                            Image(systemName: "checkmark.circle")
                        }
                        .accessibilityLabel("全选")
                        .tint(nil)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        confirmation = categoriesToClear
                        showsConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("清理")
                    .tint(nil)
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

/// UITableView headers need measuring again once their actual width is known.
private final class IntroCardTableView: UITableView {
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let header = tableHeaderView, bounds.width > 0 else { return }
        let size = header.systemLayoutSizeFitting(
            CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let target = CGSize(width: bounds.width, height: ceil(size.height))
        if header.frame.size != target {
            header.frame.size = target
            tableHeaderView = header
        }
    }
}

private struct CacheCategoryList: UIViewRepresentable {
    let sizes: [AppCacheCategory: Int64]
    @Binding var selecting: Bool
    @Binding var selected: Set<AppCacheCategory>
    let clearing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITableView {
        let table = IntroCardTableView(frame: .zero, style: .insetGrouped)
        table.allowsSelectionDuringEditing = true
        table.allowsMultipleSelectionDuringEditing = true
        table.estimatedRowHeight = 52
        table.rowHeight = UITableView.automaticDimension
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let header = UIView()
        let card = UIHostingConfiguration {
            SettingsIntroCard(title: "缓存管理", symbol: "internaldrive",
                              description: "查看各类缓存占用，选择类别清理或一次清理全部缓存。")
        }.margins(.all, 0).makeContentView()
        card.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            card.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            card.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12)
        ])
        table.tableHeaderView = header
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
            content.prefersSideBySideTextAndSecondaryText = true
            content.textProperties.numberOfLines = 0
            content.textProperties.lineBreakMode = .byWordWrapping
            content.textProperties.adjustsFontSizeToFitWidth = false
            content.secondaryTextProperties.numberOfLines = 1
            content.text = VesperLocalization.string(category.label)
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
