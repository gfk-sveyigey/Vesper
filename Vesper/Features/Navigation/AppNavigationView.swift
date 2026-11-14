import SwiftUI
import UIKit
import Combine

private enum NavigationTab: Hashable {
    case section(AppSection)
    case multifunction
}

struct AppNavigationView: View {
    @AppStorage("navigation.icons") private var icons = "{}"
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("navigation.multifunctionEnabled") private var multifunctionEnabled = true
    @AppStorage("navigation.gestureOrder") private var gestures = "tap,longPress"
    @AppStorage("navigation.actionOrder") private var actions = "tabs,search"
    @AppStorage("miniPlayer.alwaysVisible") private var miniPlayerAlwaysVisible = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var collapseToken: UUID?
    @State private var currentPage: AppSection = .media
    @State private var tabSelection: NavigationTab = .section(.media)
    @State private var isExpanded = false
    @State private var didInitializeNavigation = false
    @State private var isSearchPresented = false
    @State private var isPreparingSearch = false
    @State private var hasPreparedSearchControl = false
    @State private var searchInputActive = false
    @State private var searchQuery = ""
    @State private var searchReturnState: SearchReturnState?
    @State private var searchStartedWithHiddenTabs = false
    @State private var tabBarFrame: CGRect = .null
    @State private var hosts = SectionHosts()
    @State private var miniPlayerCoordinator = MiniPlayerPositionCoordinator()
    // Playback has not been connected yet; the layer remains ready but hidden.
    @State private var hasPlayableContent = false

    private var enabledSections: [AppSection] {
        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        let ordered = saved + AppSection.allCases.filter { !saved.contains($0) }
        let excluded = Set(hidden.split(separator: ",").map(String.init))
        return ordered.filter { $0 == .settings || !excluded.contains($0.rawValue) }
    }

    private var showPrimaryTabs: Bool { isPreparingSearch || isSearchPresented || !multifunctionEnabled || isExpanded }

    var body: some View {
        ZStack {
            VesperTheme.background.ignoresSafeArea()
            SystemTabLayer {
                TabView(selection: Binding(
                    get: { tabSelection },
                    set: {
                        selectTab($0)
                    }
                )) {
                    primaryTabs
                    Tab(multifunctionTitle, systemImage: multifunctionSymbol, value: NavigationTab.multifunction, role: .search) {
                        // Mount on first preparation and retain the navigation/search
                        // context when cancelling so native dismissal can finish.
                        if hasPreparedSearchControl {
                            NavigationStack {
                                Color.clear
                            }
                            .vesperSystemNavigationBar()
                            .searchable(text: $searchQuery, isPresented: Binding(
                                get: { searchInputActive },
                                set: { active in
                                    guard !active || isSearchPresented else {
                                        return
                                    }
                                    searchInputActive = active
                                }
                            ), prompt: "搜索当前媒体来源")
                            .task(id: isSearchPresented) {
                                guard isSearchPresented else { return }
                                await Task.yield()
                                guard !Task.isCancelled, isSearchPresented else { return }
                                activateSearchInput()
                            }
                        } else {
                            Color.clear
                        }
                    }
                }
                // UIKit can reuse positional tab items after a dynamic reorder,
                // leaving an old image attached to a different section. Recreate
                // only the native tab layer when its ordering changes. Icon edits
                // update Tab labels in place and never rebuild the tab layer. Page Hosts
                // and their navigation histories live outside this identity.
                .id(order)
                .background(MultifunctionGestures(
                    tap: { performGesture("tap") },
                    longPress: { performGesture("longPress") },
                    enabled: !isSearchPresented,

                    reselected: { index in
                        guard !isSearchPresented, !isPreparingSearch, showPrimaryTabs,
                              enabledSections.indices.contains(index), enabledSections[index] == currentPage else { return }
                        hosts.pop(currentPage)
                    },
                    reportFrame: { frame in
                        if tabBarFrame != frame {
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { tabBarFrame = frame }
                        }
                    }
                ))
            }
            .zIndex(1)

            // This sibling owns the ordinary pages, independently of TabView.
            // Hosts fill the viewport; child safe areas reserve the actual native bar.
            MiniPlayerLayer(
                hasPlayableContent: hasPlayableContent,
                alwaysVisible: miniPlayerAlwaysVisible,
                isSearchPresented: isSearchPresented,
                isPreparingSearch: isPreparingSearch,
                tabBarVisible: showPrimaryTabs,
                tabBarFrame: tabBarFrame,
                coordinator: miniPlayerCoordinator
            )
            .zIndex(2)

            ContentHost(
                hosts: hosts,
                openSection: { selectTab(.section($0)) },
                currentPage: currentPage,
                isSearchPresented: isSearchPresented,
                showPrimaryTabs: showPrimaryTabs,
                searchQuery: searchQuery,
                tabBarFrame: tabBarFrame
            ) {
                guard multifunctionEnabled, !isSearchPresented, !isPreparingSearch else { return }
                collapsePrimaryTabs()
            }

        }
        .ignoresSafeArea(.container)
        .onChange(of: tabBarFrame) { _, frame in
            miniPlayerCoordinator.update(frame: frame, isTabBarVisible: showPrimaryTabs)
        }
        .onChange(of: showPrimaryTabs) { _, visible in
            miniPlayerCoordinator.setTabBarVisible(visible)
        }
        .task(id: isPreparingSearch) {
            guard isPreparingSearch else { return }
            // Yield after mounting the search context, then select its native tab
            // separately from presenting results and requesting input focus.
            await Task.yield()
            guard !Task.isCancelled, isPreparingSearch else { return }
            do {
                try await Task.sleep(for: .milliseconds(0))
            } catch { return }
            guard !Task.isCancelled, isPreparingSearch else { return }
            tabSelection = .multifunction
            await Task.yield()
            guard !Task.isCancelled, isPreparingSearch else { return }
            isSearchPresented = true
            isPreparingSearch = false
            synchronizeTabSelection()
        }
        .onAppear {
            if !didInitializeNavigation {
                didInitializeNavigation = true
                if multifunctionEnabled && !isSearchPresented { isExpanded = false }
            }
            synchronizeTabSelection()
        }
        .onChange(of: showPrimaryTabs) { _, _ in synchronizeTabSelection() }
        .onDisappear { cancelPendingCollapse() }
        .onChange(of: multifunctionEnabled) { _, enabled in
            cancelPendingCollapse()
            if !enabled { isExpanded = true }
            synchronizeTabSelection()
        }
        .onChange(of: enabledSections) { _, _ in synchronizeTabSelection() }
        .onChange(of: isSearchPresented) { _, _ in
            synchronizeTabSelection()
        }
        .onChange(of: searchInputActive) { old, active in
            if old && !active && isSearchPresented { closeSearch() }
        }

    }

    private var multifunctionTitle: String {
        isSearchPresented || !multifunctionEnabled ? VesperLocalization.string("搜索") : VesperLocalization.string("多功能")
    }

    private var multifunctionSymbol: String {
        isSearchPresented || !multifunctionEnabled ? "magnifyingglass" : "square.grid.2x2"
    }

    private var primaryTabs: some TabContent<NavigationTab> {
        TabSection("主要功能") {
            ForEach(enabledSections) { section in
                Tab(section.title, systemImage: section.symbol, value: NavigationTab.section(section)) {
                    TransparentTabPlaceholder()
                }
            }
        }
        .hidden(!showPrimaryTabs)
    }

    private func selectTab(_ tab: NavigationTab) {
        guard case let .section(section) = tab else {
            // System search selection is accepted only in the search session.
            if isSearchPresented { tabSelection = tab }
            return
        }
        // SwiftUI can write the currently selected normal tab back while
        // expanding the group. This is not a request to cancel preparation.
        if isPreparingSearch && section == currentPage { return }
        if isSearchPresented { closeSearch() }
        currentPage = section
        synchronizeTabSelection()
    }

    private func synchronizeTabSelection() {
        if isSearchPresented {
            tabSelection = .multifunction
        } else if showPrimaryTabs {
            tabSelection = .section(enabledSections.contains(currentPage) ? currentPage : enabledSections.first ?? .settings)
        } else if multifunctionEnabled {
            // On startup keep media selected without revealing the hidden group.
            // After an explicit collapse, move selection outside the hidden tabs.
            tabSelection = didInitializeNavigation ? .multifunction : .section(.media)
        } else {
            tabSelection = .section(enabledSections.contains(currentPage) ? currentPage : enabledSections.first ?? .settings)
        }
    }

    private func collapsePrimaryTabs() {
        guard multifunctionEnabled, !isSearchPresented, !isPreparingSearch, collapseTask == nil else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            searchInputActive = false
        }
        guard hasPreparedSearchControl else {
            finishCollapsingPrimaryTabs()
            return
        }
        let token = UUID()
        collapseToken = token
        collapseTask = Task { @MainActor in
            defer {
                if collapseToken == token {
                    collapseTask = nil
                    collapseToken = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(0))
                guard !Task.isCancelled, multifunctionEnabled, !isSearchPresented, !isPreparingSearch else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { hasPreparedSearchControl = false }
                try await Task.sleep(for: .milliseconds(0))
                guard !Task.isCancelled else { return }
                finishCollapsingPrimaryTabs()
            } catch { return }
        }
    }

    private func cancelPendingCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
        collapseToken = nil
    }

    private func finishCollapsingPrimaryTabs() {
        guard multifunctionEnabled, !isSearchPresented, !isPreparingSearch else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isExpanded = false
            synchronizeTabSelection()
        }
    }

    private func performGesture(_ gesture: String) {
        guard !isSearchPresented, !isPreparingSearch else { return }
        if !multifunctionEnabled {
            if gesture == "tap" { openSearch() }
            return
        }
        let gestureValues = gestures.split(separator: ",").map(String.init)
        let actionValues = actions.split(separator: ",").map(String.init)
        guard let index = gestureValues.firstIndex(of: gesture), actionValues.indices.contains(index) else { return }
        if actionValues[index] == "tabs" {
            if isExpanded {
                // Use the same deferred collapse path as content gestures.
                DispatchQueue.main.async { collapsePrimaryTabs() }
                return
            }
            isExpanded = true
        } else {
            openSearch()
        }
        synchronizeTabSelection()
    }

    private struct SearchReturnState {
        let page: AppSection
        let expanded: Bool
        let tab: NavigationTab
    }

    private func openSearch() {
        guard !isSearchPresented, !isPreparingSearch else { return }
        cancelPendingCollapse()
        searchReturnState = SearchReturnState(page: currentPage, expanded: isExpanded, tab: tabSelection)
        searchQuery = ""
        searchStartedWithHiddenTabs = multifunctionEnabled && !showPrimaryTabs
        if searchStartedWithHiddenTabs { isExpanded = true }
        hasPreparedSearchControl = true
        isPreparingSearch = true
        synchronizeTabSelection()
    }

    private func activateSearchInput() {
        // The Search Tab owns the native search control; ContentHost owns results.
        guard isSearchPresented else { return }
        searchInputActive = true
    }

    private func closeSearch() {
        guard isSearchPresented || isPreparingSearch else { return }
        isPreparingSearch = false
        searchInputActive = false
        isSearchPresented = false
        if let previous = searchReturnState {
            currentPage = previous.page
            isExpanded = searchStartedWithHiddenTabs ? true : previous.expanded
            tabSelection = searchStartedWithHiddenTabs ? .section(previous.page) : previous.tab
        }
        searchReturnState = nil
        searchStartedWithHiddenTabs = false
        synchronizeTabSelection()
    }

}

/// UIKit-created hosting roots do not inherit the outer SwiftUI environment.
private struct HostedPageEnvironment<Content: View>: View {
    @AppStorage("language.code") private var languageCode = "system"
    @AppStorage("appearance.accent") private var accent = "vesper"
    @ViewBuilder let content: () -> Content

    var body: some View {
        // Measure outside NavigationStack so this inset excludes its navigation
        // bar. Root pages can underlap an empty bar while avoiding the status bar.
        GeometryReader { geometry in
            content()
                .environment(\.vesperWindowTopInset, geometry.safeAreaInsets.top)
                .environment(\.locale, VesperLocalization.locale(for: languageCode))
                .tint(VesperTheme.accent(accent))
        }
    }
}

/// Four persistent hosts, each with its own NavigationStack.
@MainActor
private final class SectionHosts {
    var openSection: (AppSection) -> Void = { _ in }
    private var histories: [AppSection: PageHistory] = [:]

    func pop(_ section: AppSection) {
        guard let history = histories[section], !history.path.isEmpty else { return }
        history.path.removeLast()
    }

    private var controllers: [AppSection: UIHostingController<AnyView>] = [:]

    func controller(for section: AppSection) -> UIHostingController<AnyView> {
        if let controller = controllers[section] { return controller }
        let page: AnyView
        switch section {
        case .media: page = AnyView(MediaView())
        case .sources: page = AnyView(SourcesView())
        case .history: page = AnyView(HistoryView())
        case .settings: page = AnyView(SettingsView(openSection: { [weak self] in self?.openSection($0) }))
        }
        let history = PageHistory()
        histories[section] = history
        let controller = UIHostingController(rootView: AnyView(HostedPageEnvironment { PageNavigation(history: history, page: page) }))
        controller.view.backgroundColor = .clear
        controllers[section] = controller
        return controller
    }
}

@MainActor
private final class PageHistory: ObservableObject {
    @Published var path = NavigationPath()
}

private struct PageNavigation: View {
    @ObservedObject var history: PageHistory
    let page: AnyView
    var body: some View { NavigationStack(path: $history.path) { page } }
}

/// Native system controls render above pages, but their empty viewport passes touches through.
private struct SystemTabLayer<Content: View>: UIViewControllerRepresentable {
    @Environment(\.locale) private var locale
    @AppStorage("appearance.accent") private var accent = "vesper"
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> SystemTabLayerController {
        SystemTabLayerController(rootView: AnyView(content().environment(\.locale, locale).tint(VesperTheme.accent(accent))))
    }

    func updateUIViewController(_ controller: SystemTabLayerController, context: Context) {
        controller.host.rootView = AnyView(content().environment(\.locale, locale).tint(VesperTheme.accent(accent)))
        controller.refreshTransparency()
        controller.view.setNeedsLayout()
    }
}

private final class SystemTabLayerController: UIViewController {
    let host: UIHostingController<AnyView>

    init(rootView: AnyView) {
        host = UIHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = SystemTabPassthroughView()
        view.backgroundColor = .clear
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshTransparency()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshTransparency()
    }

    func refreshTransparency() {
        // TabView may create new UIKit page controllers during first expansion
        // or reorder. Keep their container backgrounds transparent independently
        // of the gesture bridge's layout callbacks. Do not touch bar materials.
        clearLoadedControllerBackgrounds(host)
    }

    private func clearLoadedControllerBackgrounds(_ controller: UIViewController) {
        if controller.isViewLoaded {
            controller.view.backgroundColor = .clear
            controller.view.isOpaque = false
        }
        for child in controller.children { clearLoadedControllerBackgrounds(child) }
    }
}

/// A placeholder can appear after its parent's last layout callback. Clear
/// only its own controller ancestry, never the sibling ContentHost or its pages.
private struct TransparentTabPlaceholder: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.clearBackgrounds() }

    final class Controller: UIViewController {
        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isOpaque = false
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            clearBackgrounds()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            clearBackgrounds()
        }

        func clearBackgrounds() {
            var current: UIViewController? = self
            while let controller = current {
                if controller.isViewLoaded {
                    controller.view.backgroundColor = .clear
                    controller.view.isOpaque = false
                }
                if controller is SystemTabLayerController { break }
                current = controller.parent
            }
        }
    }
}

private final class SystemTabPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        var ancestor = hit
        while let candidate = ancestor, candidate !== self {
            // The native cancel button can be a sibling of UISearchBar.
            // Allow its UIControl ancestry rather than swallowing the touch.
            if candidate is UITabBar || candidate is UISearchBar || candidate is UIControl {
                return hit
            }
            ancestor = candidate.superview
        }
        return nil
    }
}

/// Child bounds always fill the container. Only their content safe area avoids the bar.
private final class PageContainerController: UIViewController {
    var tabBarFrame: CGRect = .null {
        didSet {
            if oldValue != tabBarFrame { viewIfLoaded?.setNeedsLayout() }
        }
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
    }

    func install(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        child.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateContentSafeAreas()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateContentSafeAreas()
    }

    private func updateContentSafeAreas() {
        guard let window = view.window else { return }
        let overlap: CGRect
        if tabBarFrame.isNull || tabBarFrame.isInfinite {
            overlap = .null
        } else {
            overlap = view.bounds.intersection(view.convert(tabBarFrame, from: window))
        }
        // During tab reconstruction UIKit can briefly report a bar at the top
        // of the window. Never turn that transient frame into a full-page inset.
        if !overlap.isNull && overlap.minY < view.bounds.midY { return }
        let bottomInset = overlap.isNull ? 0 : max(0, view.bounds.maxY - overlap.minY - view.safeAreaInsets.bottom)
        for child in children {
            var insets = child.additionalSafeAreaInsets
            if insets.bottom != bottomInset {
                insets.bottom = bottomInset
                child.additionalSafeAreaInsets = insets
            }
        }
    }
}

private struct ContentHost: UIViewControllerRepresentable {
    let hosts: SectionHosts
    let openSection: (AppSection) -> Void
    let currentPage: AppSection
    let isSearchPresented: Bool
    let showPrimaryTabs: Bool
    let searchQuery: String
    let tabBarFrame: CGRect
    let contentTapped: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(contentTapped: contentTapped) }

    func makeUIViewController(context: Context) -> PageContainerController {
        hosts.openSection = openSection
        let container = PageContainerController()
        container.tabBarFrame = tabBarFrame
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = context.coordinator
        container.view.addGestureRecognizer(tap)
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPressed(_:)))
        longPress.cancelsTouchesInView = false
        longPress.delegate = context.coordinator
        container.view.addGestureRecognizer(longPress)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
            swipe.direction = direction
            swipe.cancelsTouchesInView = false
            swipe.delegate = context.coordinator
            container.view.addGestureRecognizer(swipe)
        }
        for section in AppSection.allCases {
            let host = hosts.controller(for: section)
            container.install(host)
            host.view.isHidden = isSearchPresented || section != currentPage
        }
        let searchHost = UIHostingController(rootView: AnyView(
            HostedPageEnvironment { SearchPage(query: searchQuery) }
        ))
        searchHost.view.accessibilityIdentifier = "search-page-host"
        searchHost.view.backgroundColor = .clear
        container.install(searchHost)
        searchHost.view.isHidden = !isSearchPresented
        context.coordinator.isSearchPresented = isSearchPresented
        context.coordinator.showPrimaryTabs = showPrimaryTabs
        return container
    }

    func updateUIViewController(_ container: PageContainerController, context: Context) {
        hosts.openSection = openSection
        container.tabBarFrame = tabBarFrame
        context.coordinator.contentTapped = contentTapped
        context.coordinator.isSearchPresented = isSearchPresented
        context.coordinator.showPrimaryTabs = showPrimaryTabs
        for section in AppSection.allCases {
            let host = hosts.controller(for: section)
            host.view.isHidden = isSearchPresented || section != currentPage
            host.view.accessibilityElementsHidden = isSearchPresented || section != currentPage
        }
        if let searchHost = container.children.first(where: { $0 is UIHostingController<AnyView> && $0.view.accessibilityIdentifier == "search-page-host" }) as? UIHostingController<AnyView> {
            searchHost.rootView = AnyView(HostedPageEnvironment { SearchPage(query: searchQuery) })
            searchHost.view.isHidden = !isSearchPresented
            searchHost.view.accessibilityElementsHidden = !isSearchPresented
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var contentTapped: () -> Void
        var isSearchPresented = false
        var showPrimaryTabs = false
        init(contentTapped: @escaping () -> Void) { self.contentTapped = contentTapped }

        @objc func tapped() {
            // Let the native control finish handling this touch before changing
            // tab visibility. Never cancel the original control's interaction.
            DispatchQueue.main.async { [weak self] in self?.contentTapped() }
        }

        @objc func longPressed(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            collapseAfterGesture()
        }

        @objc func swiped(_ recognizer: UISwipeGestureRecognizer) {
            collapseAfterGesture()
        }

        private func collapseAfterGesture() {
            DispatchQueue.main.async { [weak self] in self?.contentTapped() }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard !isSearchPresented, showPrimaryTabs else { return false }
            var candidate = touch.view
            while let current = candidate {
                if current is UIControl || current is UITextField || current is UITextView { return false }
                if current.accessibilityTraits.contains(.button) { return false }
                candidate = current.superview
            }
            return true
        }
    }

}

/// Only bridges gestures on the system tab bar; does not replace its delegate,
/// tabs, selection, or access private UIKit view types.
private struct MultifunctionGestures: UIViewControllerRepresentable {
    let tap: () -> Void
    let longPress: () -> Void
    let enabled: Bool
    let reselected: (Int) -> Void
    let reportFrame: (CGRect) -> Void

    func makeUIViewController(context: Context) -> GestureController {
        GestureController(tap: tap, longPress: longPress, reportFrame: reportFrame)
    }

    func updateUIViewController(_ controller: GestureController, context: Context) {
        controller.reselected = reselected
        controller.tapAction = tap
        controller.longPressAction = longPress
        controller.reportFrame = reportFrame
        controller.gesturesEnabled = enabled
        controller.installWhenReady()
    }

    static func dismantleUIViewController(_ controller: GestureController, coordinator: ()) {
        controller.uninstall()
    }

    final class GestureController: UIViewController, UIGestureRecognizerDelegate {
        var tapAction: () -> Void
        var longPressAction: () -> Void
        var reportFrame: (CGRect) -> Void
        var gesturesEnabled = true
        var reselected: (Int) -> Void = { _ in }
        private var reselectedIndex: Int?
        private lazy var reselectRecognizer = UITapGestureRecognizer(target: self, action: #selector(reselectTapped))
        private weak var installedBar: UITabBar?
        private lazy var tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
        private lazy var pressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))

        init(tap: @escaping () -> Void, longPress: @escaping () -> Void, reportFrame: @escaping (CGRect) -> Void) {
            self.reportFrame = reportFrame
            tapAction = tap
            longPressAction = longPress
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installWhenReady()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            installWhenReady()
        }

        func installWhenReady() {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            guard let controller = findTabController(in: root) else { return }
            controller.view.backgroundColor = .clear
            controller.view.isOpaque = false
            for child in controller.children { clearContainerBackgrounds(in: child) }
            for tab in controller.tabs {
                if let search = tab as? UISearchTab {
                    // App gestures own search activation, including when this tab is
                    // selected to keep the primary group collapsed.
                    search.automaticallyActivatesSearch = false

                }
            }
            let bar = controller.tabBar
            if let window = bar.window, !bar.bounds.isEmpty {
                let frame = bar.convert(bar.bounds, to: window)
                // Keep the last usable frame through first layout/reordering;
                // an unattached/transitional bar is not a content safe area.
                if frame.minY >= window.bounds.midY, frame.intersects(window.bounds) {
                    DispatchQueue.main.async { [weak self] in self?.reportFrame(frame) }
                }
            }
            guard installedBar !== bar else { return }
            uninstall()
            installedBar = bar
            reselectRecognizer.delegate = self
            reselectRecognizer.cancelsTouchesInView = false
            tapRecognizer.delegate = self
            pressRecognizer.delegate = self
            tapRecognizer.cancelsTouchesInView = true
            pressRecognizer.cancelsTouchesInView = true
            tapRecognizer.require(toFail: pressRecognizer)
            bar.addGestureRecognizer(reselectRecognizer)
            bar.addGestureRecognizer(tapRecognizer)
            bar.addGestureRecognizer(pressRecognizer)
        }

        private func clearContainerBackgrounds(in controller: UIViewController) {
            controller.view.backgroundColor = .clear
            controller.view.isOpaque = false
            for child in controller.children { clearContainerBackgrounds(in: child) }
        }

        private func findTabController(in controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            for child in controller.children {
                if let tabs = findTabController(in: child) { return tabs }
            }
            return nil
        }

        func uninstall() {
            installedBar?.removeGestureRecognizer(reselectRecognizer)
            installedBar?.removeGestureRecognizer(tapRecognizer)
            installedBar?.removeGestureRecognizer(pressRecognizer)
            installedBar = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let bar = installedBar else { return false }
            if gestureRecognizer === reselectRecognizer {
                reselectedIndex = nil
                guard let items = bar.items, items.count > 1 else { return false }
                let point = touch.location(in: nil)
                let index = items.firstIndex { !$0.accessibilityFrame.isEmpty && $0.accessibilityFrame.contains(point) }
                // Liquid Glass keeps Search in its own trailing platter.
                let localX = touch.location(in: bar).x
                let primaryWidth = max(1, bar.bounds.width - 88)
                guard localX < primaryWidth else { return false }
                let hitIndex = index ?? min(items.count - 2, max(0, Int(localX / primaryWidth * CGFloat(items.count - 1))))
                guard items[hitIndex] === bar.selectedItem else { return false }
                reselectedIndex = hitIndex
                return true
            }
            guard gesturesEnabled else { return false }
            // The independent search-role item occupies the trailing platter.
            // Use the public item's accessibility frame when UIKit supplies it.
            let hitsItem: Bool
            if let frame = bar.items?.last?.accessibilityFrame, !frame.isEmpty {
                hitsItem = frame.contains(touch.location(in: nil))
            } else {
                hitsItem = touch.location(in: bar).x >= bar.bounds.width - 88
            }
            return hitsItem
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        @objc private func reselectTapped() {
            guard let index = reselectedIndex else { return }
            DispatchQueue.main.async { [weak self] in self?.reselected(index) }
        }
        @objc private func tapped() { tapAction() }
        @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .ended { longPressAction() }
        }

    }
}

/// Search results hosted independently of the native search control.
private struct SearchPage: View {
    let query: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                query.isEmpty ? "搜索媒体" : "暂无搜索结果",
                systemImage: "magnifyingglass",
                description: Text("搜索范围为当前媒体来源。真实媒体来源尚未接入。")
            )
            .vesperSystemNavigationBar()
        }
    }
}


@MainActor
private final class MiniPlayerPositionCoordinator: ObservableObject {
    @Published private(set) var tabBarHeight: CGFloat = 0
    private var frozenHeight: CGFloat = 0
    private var isVisible = false

    func update(frame: CGRect, isTabBarVisible: Bool) {
        guard frame.isNull == false, frame.isInfinite == false, frame.height > 0 else { return }
        if isTabBarVisible {
            tabBarHeight = frame.height
            frozenHeight = frame.height
            isVisible = true
        } else if !isVisible {
            frozenHeight = frame.height
        }
    }

    func setTabBarVisible(_ visible: Bool) {
        if visible {
            isVisible = true
            tabBarHeight = max(tabBarHeight, frozenHeight)
        } else {
            isVisible = false
            tabBarHeight = frozenHeight
        }
    }
}

private struct MiniPlayerLayer: View {
    let hasPlayableContent: Bool
    let alwaysVisible: Bool
    let isSearchPresented: Bool
    let isPreparingSearch: Bool
    let tabBarVisible: Bool
    let tabBarFrame: CGRect
    @ObservedObject var coordinator: MiniPlayerPositionCoordinator

    private var shouldShow: Bool {
        (hasPlayableContent || alwaysVisible) && !isSearchPresented && !isPreparingSearch
    }

    var body: some View {
        GeometryReader { geometry in
            if shouldShow {
                MiniPlayerCard(isCompact: !tabBarVisible)
                    .padding(.horizontal, 12)
                    .padding(.bottom, max(8, coordinator.tabBarHeight + geometry.safeAreaInsets.bottom + 6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.86), value: tabBarVisible)
            }
        }
        .allowsHitTesting(shouldShow)
        .accessibilityHidden(!shouldShow)
    }
}

private struct MiniPlayerCard: View {
    let isCompact: Bool

    var body: some View {
        HStack(spacing: isCompact ? 8 : 12) {
            Image(systemName: "music.note")
                .font(isCompact ? .subheadline : .title3)
                .frame(width: isCompact ? 30 : 42, height: isCompact ? 30 : 42)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: isCompact ? 8 : 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("正在播放")
                    .font(isCompact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .lineLimit(1)
                if !isCompact {
                    Text("媒体内容")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button { } label: {
                Image(systemName: "play.fill")
                    .font(isCompact ? .subheadline : .headline)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("播放")
        }
        .padding(.horizontal, isCompact ? 10 : 14)
        .padding(.vertical, isCompact ? 6 : 10)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: isCompact ? 14 : 18))
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: isCompact)
    }
}
