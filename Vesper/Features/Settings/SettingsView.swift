import SwiftUI
import UIKit

private enum SettingsRoute: Hashable {
    case tabs, appearance, logs, licenses, gestures, playback, subtitles, danmaku

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
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var playback: PlaybackSession
    @AppStorage("language.code") private var languageCode = "system"

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
                                .foregroundStyle(Color("VesperPrimaryText"))
                            Spacer()
                            Text("尚未连接").foregroundStyle(.secondary)
                        }.padding(12)
                }
                settingsLink(.licenses, title: "开源许可", symbol: "doc.plaintext")
                Text("Vesper \(version) · Aholic")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
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
                }
            }
            .vesperNavigationTitle(route.title)
            .vesperNavigationStyle(.inline)
        }
    }

    private func settingsLink(_ route: SettingsRoute, title: LocalizedStringKey, symbol: String) -> some View {
        NavigationLink(value: route) {
            HStack {
                SettingsLabel(title, symbol: symbol)
                    .foregroundStyle(Color("VesperPrimaryText"))
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
    @AppStorage("navigation.icons") private var icons = "{}"
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("navigation.defaultTab") private var defaultTab = "media"
    @AppStorage("miniPlayer.enabled") private var miniPlayerEnabled = true
    @AppStorage("miniPlayer.alwaysVisible") private var miniPlayerAlwaysVisible = true
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
                SettingsIntroCard(title: "标签设置", symbol: "rectangle.3.group", description: "调整标签排列顺序和图标。")

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
                SettingsSection {
                    Toggle(isOn: $miniPlayerEnabled) {
                        SettingsLabel("启用迷你播放器", symbol: "play.rectangle")
                    }
                    if #available(iOS 26.1, *) {
                        Toggle(isOn: $miniPlayerAlwaysVisible) {
                            SettingsLabel("常显迷你播放器", symbol: "eye")
                        }
                        .disabled(!miniPlayerEnabled)
                    }
                } footer: {
                    Text("关闭常显后，仅在有可播放内容时显示迷你播放器。")
                }
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(sections) { section in
                            Menu {
                                ForEach(section.iconChoices, id: \.self) { symbol in
                                    Button { setIcon(symbol, for: section) } label: {
                                        Label {
                                            Text(iconTitle(symbol))
                                        } icon: { Image(systemName: symbol) }
                                    }
                                }
                            } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: section.symbol)
    .font(.system(size: 24, weight: .medium))
                                        .foregroundStyle(.tint)
                                    Text(section.title)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 88)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                                .contentShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .accessibilityHint("更换图标")
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
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
                icons = "{}"
                hidden = ""
                defaultTab = "media"
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将恢复标签的排列顺序、图标、显示状态和默认标签页。")
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
    private func setIcon(_ symbol: String, for section: AppSection) {
        let data = icons.data(using: .utf8) ?? Data()
        var values = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        values[section.rawValue] = symbol
        if let data = try? JSONEncoder().encode(values), let saved = String(data: data, encoding: .utf8) {
            icons = saved
        }
    }

    private func iconTitle(_ symbol: String) -> LocalizedStringKey {
        switch symbol {
        case "film": "胶片"
        case "play.rectangle": "播放"
        case "tv": "电视"
        case "photo.on.rectangle": "相册"
        case "externaldrive": "硬盘"
        case "folder": "文件夹"
        case "server.rack": "服务器"
        case "network": "网络"
        case "clock.arrow.circlepath": "历史"
        case "clock": "时钟"
        case "list.bullet": "列表"
        case "calendar": "日历"
        case "gearshape": "齿轮"
        case "gear": "圆形齿轮"
        case "slider.horizontal.3": "滑块"
        default: "开关"
        }
    }

}


private struct TabOrderSettingsView: View {
    @AppStorage("navigation.icons") private var icons = "{}"
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
private struct SettingsLabel: View {
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
                .foregroundStyle(Color("VesperPrimaryText"))
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
