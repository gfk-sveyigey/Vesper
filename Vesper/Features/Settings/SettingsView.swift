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
        appLock.biometricType != .none
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
            if appLock.authenticationRequest != .appUnlock {
                Button("取消", systemImage: "xmark") { appLock.cancelAuthentication() }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.regularMaterial).ignoresSafeArea() }
        .contentShape(Rectangle())
        .task(id: appLock.authenticationRequestID) {
            pin = ""
            errorMessage = nil
            failures = 0
            showPassword = false
            biometricType = appLock.biometricType
            if !passwordOnly, biometricEnabled, biometricPriority, biometricType != .none {
                let requestID = appLock.authenticationRequestID
                if appLock.claimAutomaticBiometricAttempt(for: requestID) {
                    await Task.yield()
                    guard appLock.authenticationRequestID == requestID,
                          appLock.authenticationRequest != nil else { return }
                    Task { @MainActor in await authenticate() }
                }
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
        let requestID = appLock.authenticationRequestID
        isAuthenticating = true
        let result = await appLock.authenticateBiometrically(reason: biometricReason)
        isAuthenticating = false
        guard appLock.authenticationRequestID == requestID,
              appLock.authenticationRequest == purpose else { return }
        switch result {
        case .success:
            finish()
        case .passwordFallback:
            showPassword = true
        case .failure:
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

struct TraktAccountSheet: View {
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

private struct SettingsNavigationStyle: ViewModifier {
    let useSharedStyle: Bool

    func body(content: Content) -> some View {
        if useSharedStyle { content.vesperNavigationStyle(.inline) }
        else { content }
    }
}

struct TabOrderSettingsView: View {
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

struct EmbyProgressPrioritySheet: View {
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

struct TabOrderDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(context.maxDetentValue, context.dynamicTypeSize.isAccessibilitySize ? 540 : 360)
    }
}

/// Inline choices for the primary and installed alternate app icons.
struct AppIconChoices: View {
    @State private var currentIcon = UIApplication.shared.alternateIconName
    @State private var iconChangeError: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            iconChoice(name: "VesperAppIcon", title: "新版图标", iconName: nil)
            iconChoice(name: "ClassicAppIcon", title: "经典图标", iconName: "ClassicIcon")
        }
        .padding(.vertical, 8)
        .alert("无法更换图标", isPresented: Binding(
            get: { iconChangeError != nil },
            set: { if !$0 { iconChangeError = nil } }
        )) {
            Button("好", role: .cancel) { iconChangeError = nil }
        } message: {
            Text(verbatim: iconChangeError ?? "")
        }
    }

    private func iconChoice(name: String, title: LocalizedStringKey, iconName: String?) -> some View {
        let selected = currentIcon == iconName
        return Button {
            guard UIApplication.shared.supportsAlternateIcons, !selected else { return }
            UIApplication.shared.setAlternateIconName(iconName) { error in
                if let error {
                    iconChangeError = error.localizedDescription
                } else {
                    currentIcon = iconName
                }
            }
        } label: {
            VStack(spacing: 8) {
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
                    }
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(Color.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!UIApplication.shared.supportsAlternateIcons)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
