import SwiftUI
import UIKit

private enum SettingsRoute: Hashable {
    case tabs, appearance, logs

    var title: LocalizedStringKey {
        switch self {
        case .tabs: "标签设置"
        case .appearance: "外观设置"
        case .logs: "运行日志"
        }
    }
}

struct SettingsView: View {
    let openSection: (AppSection) -> Void
    @AppStorage("language.code") private var languageCode = "system"

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        List {
            Section {
                VesperLargeTitle("设置")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listSectionMargins([.horizontal, .bottom], 0)
            Section("应用") {
                NavigationLink(value: SettingsRoute.tabs) { SettingsLabel("标签设置", symbol: "rectangle.3.group") }
                NavigationLink(value: SettingsRoute.appearance) { SettingsLabel("外观设置", symbol: "paintpalette") }
                NavigationLink(value: SettingsRoute.logs) { SettingsLabel("运行日志", symbol: "doc.text") }
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
            }
            Section {
                LabeledContent { Text("尚未接入") } label: { SettingsLabel("播放器偏好", symbol: "play.rectangle") }
                LabeledContent { Text("尚未连接") } label: { SettingsLabel("IMDb", symbol: "film") }
                LabeledContent { Text("尚未连接") } label: { Label {
                    Text(verbatim: "Trakt")
                } icon: {
                    Image("TraktIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.tint)
                } }
            } header: {
                Text("后续功能")
            } footer: {
                Text("播放器和外部服务将在对应阶段接入，当前不会提供无效的开关或连接按钮。")
            }
            Section {
                EmptyView()
            } footer: {
                Text("Vesper \(version) · Aholic")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
        .scrollContentBackground(.hidden)
        .vesperImmersiveTitle("设置")
        .navigationDestination(for: SettingsRoute.self) { route in
            Group {
                switch route {
                case .tabs: TabSettingsView(openSection: openSection)
                case .appearance: AppearanceSettingsView()
                case .logs: RuntimeLogsView()
                }
            }
            .vesperNavigationTitle(route.title)
            .vesperNavigationStyle(.inline)
        }
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
        List {
            SettingsIntroCard(title: "运行日志", symbol: "doc.text", description: "查看运行日志，设置保留时间，或分享完整日志文件以协助排查问题。")

            if store.storageError != nil { Text("日志文件写入失败。").foregroundStyle(.red) }
            Section("保留规则") {
                Picker(selection: $retentionDays) {
                    Text("无限制").tag(0)
                    ForEach([1, 3, 7, 14, 30, 90], id: \.self) { days in
                        Text(String(format: VesperLocalization.string("%d 天"), locale: VesperLocalization.locale(for: UserDefaults.standard.string(forKey: "language.code") ?? "system"), arguments: [days])).tag(days)
                    }
                } label: { Text("保留时间") }
                .pickerStyle(.menu)
            }
            Section(String(format: VesperLocalization.string("日志（%d）"), locale: VesperLocalization.locale(for: UserDefaults.standard.string(forKey: "language.code") ?? "system"), arguments: [store.entries.count])) {
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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
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
        .confirmationDialog("确定清空所有日志？", isPresented: $isShowingClearConfirmation, titleVisibility: .visible) {
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

    var body: some View {
        Form {
            SettingsIntroCard(title: "外观设置", symbol: "paintpalette", description: "选择喜欢的主题、主题色和应用图标，让 Vesper 更符合你的偏好。")

            Section {
                Picker(selection: $appearanceMode) {
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
                Button("重置主题色") { accent = "vesper" }
                    .disabled(accent == "vesper")
            } footer: {
                Text("主题模式控制浅色或深色外观；主题色应用于选中状态和交互强调色。")
            }
            Section("更换图标") {
                AppIconChoices()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
    }
}


struct TabSettingsView: View {
    @AppStorage("navigation.icons") private var icons = "{}"
    let openSection: (AppSection) -> Void
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("navigation.multifunctionEnabled") private var multifunctionEnabled = true
    @State private var isShowingResetConfirmation = false
    @State private var isShowingGestureSettings = false
    @State private var isShowingOrderSettings = false
    @State private var isShowingEnableConfirmation = false

    private var sections: [AppSection] {
        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        return saved + AppSection.allCases.filter { !saved.contains($0) }
    }

    var body: some View {
        List {
            SettingsIntroCard(title: "标签设置", symbol: "rectangle.3.group", description: "选择显示的标签，调整排列顺序与多功能按钮，也可从这里打开隐藏的页面。")

            Section {
                ForEach(sections.filter { $0 != .settings }) { section in
                    Toggle(isOn: Binding(
                        get: { !hidden.split(separator: ",").contains(Substring(section.rawValue)) },
                        set: { visible in
                            var values = Set(hidden.split(separator: ",").map(String.init))
                            if visible { values.remove(section.rawValue) } else { values.insert(section.rawValue) }
                            hidden = values.sorted().joined(separator: ",")
                        }
                    )) { Label(section.title, systemImage: section.filledSymbol) }
                }
            } header: {
                Text("显示标签")
            } footer: {
                Text("关闭只隐藏入口，不清除页面数据。设置标签始终保留。")
            }
            Section("跳转标签") {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(sections.filter { $0 != .settings }) { section in
                        Button { openSection(section) } label: {
                            VStack(spacing: 8) {
                                Image(systemName: section.filledSymbol)
.font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(.tint)
                                Text(section.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 88)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section("标签图标") {
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
                                Image(systemName: section.filledSymbol)
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
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        if multifunctionEnabled {
                            multifunctionEnabled = false
                        } else {
                            isShowingEnableConfirmation = true
                        }
                    } label: {
                        Label(
                            multifunctionEnabled ? "关闭多功能按钮" : "启用多功能按钮",
                            systemImage: multifunctionEnabled ? "square.grid.2x2.fill" : "square.grid.2x2"
                        )
                    }
                    if multifunctionEnabled {
                        Button { isShowingGestureSettings = true } label: {
                            Label("手势与动作", systemImage: "hand.tap")
                        }
                    }
                } label: {
                    Image(systemName: multifunctionEnabled ? "square.grid.2x2.fill" : "square.grid.2x2")
                }
                .accessibilityLabel("多功能按钮设置")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("标签顺序", systemImage: "arrow.up.arrow.down") { isShowingOrderSettings = true }
                    Button("恢复默认", systemImage: "arrow.counterclockwise") { isShowingResetConfirmation = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("标签设置")
            }
        }
        .alert("启用多功能按钮？", isPresented: $isShowingEnableConfirmation) {
            Button("启用") { multifunctionEnabled = true }
            Button("取消", role: .cancel) { }
        } message: {
            Text("多功能按钮仍处于试验阶段，可能出现交互或显示问题；如影响使用，请关闭此功能。")
        }
        .alert("恢复默认标签设置？", isPresented: $isShowingResetConfirmation) {
            Button("恢复默认", role: .destructive) {
                order = "media,sources,history,settings"
                hidden = ""
                icons = "{}"
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将恢复标签的显示状态、排列顺序和图标。")
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
                        ToolbarItem(placement: .cancellationAction) {
                            Button { isShowingOrderSettings = false } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("关闭")
                        }
                    }
            }
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.hidden)
            .interactiveDismissDisabled(false)
            .presentationBackground(VesperTheme.background)
        }
        .sheet(isPresented: $isShowingGestureSettings) {
            NavigationStack {
                GestureActionSettingsView()
                    .navigationTitle("手势与动作")
                    .vesperNavigationStyle(.inline)
                    .toolbarRole(.automatic)
                    .navigationBarBackButtonHidden(true)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { isShowingGestureSettings = false } label: {
                                Image(systemName: "xmark")
                            }
                            .accessibilityLabel("关闭")
                        }
                        ToolbarItem(placement: .principal) {
                            Text("手势与动作").font(.headline)
                        }
                    }
            }
            .presentationDetents([.height(360)])
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


/// SwiftUI sheets support swipe dismissal; observe only taps outside the
/// presented frame to add backdrop dismissal without consuming sheet controls.
private struct SheetOutsideDismiss: UIViewControllerRepresentable {
    let dismiss: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(dismiss: dismiss) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.dismissAction = dismiss }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.uninstall() }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var dismissAction: () -> Void
        private weak var container: UIView?
        private weak var sheet: UIPresentationController?
        private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))

        init(dismiss: @escaping () -> Void) {
            dismissAction = dismiss
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            var current: UIViewController? = self
            while let controller = current {
                if let presentation = controller.presentationController,
                   let view = presentation.containerView {
                    uninstall()
                    sheet = presentation
                    container = view
                    tap.delegate = self
                    tap.cancelsTouchesInView = false
                    view.addGestureRecognizer(tap)
                    break
                }
                current = controller.parent
            }
        }
        func uninstall() {
            container?.removeGestureRecognizer(tap)
            container = nil
            sheet = nil
        }
        @objc private func tapped() { dismissAction() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let sheet, let container else { return false }
            return !sheet.frameOfPresentedViewInContainerView.contains(touch.location(in: container))
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
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
        List {
            ForEach(sections) { section in
                Label(section.title, systemImage: section.filledSymbol)
            }
            .onMove { offsets, destination in
                var updated = sections
                updated.move(fromOffsets: offsets, toOffset: destination)
                // Shared storage updates both the settings list and native tabs.
                order = updated.map(\.rawValue).joined(separator: ",")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
        .environment(\.editMode, .constant(.active))
    }
}

private struct GestureActionSettingsView: View {
    @AppStorage("navigation.gestureOrder") private var gestureOrder = "tap,longPress"
    @AppStorage("navigation.actionOrder") private var actionOrder = "tabs,search"

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    GestureOrderColumn(storage: $gestureOrder, names: ["tap": "单击", "longPress": "长按"])
                    GestureOrderColumn(storage: $actionOrder, names: ["tabs": "展开标签栏", "search": "进入搜索"])
                }
                Text("分别拖动两列项目，同一行的手势与动作配对并自动保存。启用多功能按钮时使用此映射；关闭时单击搜索按钮进入搜索，长按无动作。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

}

/// Reorder only within a column. A local drag moves the actual card, rather
/// than starting a transferable copy session (and displaying its plus badge).
private struct GestureOrderColumn: View {
    @Binding var storage: String
    let names: [String: String]
    @ScaledMetric(relativeTo: .body) private var rowHeight = 52.0
    @GestureState private var dragOffset = CGSize.zero
    @GestureState private var isDragging = false
    @State private var draggedValue: String?
    @State private var initialIndex = 0
    @State private var localValues: [String] = []
    @State private var feedback = UISelectionFeedbackGenerator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var coordinateSpace

    private var values: [String] {
        localValues.isEmpty ? storage.split(separator: ",").map(String.init) : localValues
    }
    private var rowStride: CGFloat { rowHeight + 16 }

    var body: some View {
        VStack(spacing: 16) {
            ForEach(values, id: \.self) { value in
                Text(LocalizedStringKey(names[value] ?? value))
                    .frame(maxWidth: .infinity)
                    .frame(height: rowHeight)
                    .padding(.horizontal, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 12).fill(Color("VesperSecondaryBackground").opacity(0.42))
                        RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                    .offset(y: offset(for: value))
                    .zIndex(draggedValue == value ? 1 : 0)
                    .gesture(
                        DragGesture(minimumDistance: 6, coordinateSpace: .named(coordinateSpace))
                            .updating($dragOffset) { drag, offset, _ in offset = drag.translation }
                            .updating($isDragging) { _, active, _ in active = true }
                            .onChanged { drag in
                                if draggedValue != value {
                                    draggedValue = value
                                    initialIndex = values.firstIndex(of: value) ?? 0
                                    feedback.prepare()
                                }
                                let target = min(values.count - 1, max(0,
                                    initialIndex + Int((drag.translation.height / rowStride).rounded())))
                                reorder(value, to: target)
                            }
                    )
                    .accessibilityHint("拖动调整配对顺序")
                    .accessibilityAction(named: Text("上移")) { move(value, by: -1) }
                    .accessibilityAction(named: Text("下移")) { move(value, by: 1) }
            }
        }
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: coordinateSpace)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: localValues)
        .onAppear { localValues = storage.split(separator: ",").map(String.init) }
        .onChange(of: storage) { _, value in
            let saved = value.split(separator: ",").map(String.init)
            if localValues != saved { localValues = saved }
        }
        .onChange(of: isDragging) { _, active in
            if !active { withAnimation(.easeInOut(duration: 0.18)) { draggedValue = nil } }
        }
    }

    private func offset(for value: String) -> CGFloat {
        guard draggedValue == value, isDragging,
              let index = values.firstIndex(of: value) else { return 0 }
        // Compensate only for the reorder's layout change, keeping the card
        // under the finger while its neighbours animate into their new places.
        return dragOffset.height + CGFloat(initialIndex - index) * rowStride
    }

    private func reorder(_ value: String, to target: Int) {
        var updated = values
        guard let from = updated.firstIndex(of: value), from != target else { return }
        updated.move(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target)
        // Animate local layout first; AppStorage is persistence, not the source
        // of the layout animation transaction.
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) { localValues = updated }
        storage = updated.joined(separator: ",")
        feedback.selectionChanged()
        feedback.prepare()
    }

    private func move(_ value: String, by delta: Int) {
        guard let index = values.firstIndex(of: value), values.indices.contains(index + delta) else { return }
        reorder(value, to: index + delta)
    }
}

/// Introductory row within the native grouped list; scales with Dynamic Type.
private struct SettingsIntroCard: View {
    let title: LocalizedStringKey
    let symbol: String
    let description: LocalizedStringKey
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 38.0

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: iconSize))
                    .foregroundStyle(.white)
                    .frame(width: iconSize + 24, height: iconSize + 24)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(description)
                    .foregroundStyle(.secondary)
                    .lineSpacing(5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
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
        Label(title, systemImage: symbol)
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
