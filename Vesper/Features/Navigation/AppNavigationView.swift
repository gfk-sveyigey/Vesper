import SwiftUI
import UIKit

private enum NavigationTab: Hashable {
    case section(AppSection)
    case multifunction
}

struct AppNavigationView: View {
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("navigation.multifunctionEnabled") private var multifunctionEnabled = true
    @AppStorage("navigation.gestureOrder") private var gestures = "tap,longPress"
    @AppStorage("navigation.actionOrder") private var actions = "tabs,search"
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
    @FocusState private var searchFocused: Bool
    @State private var searchReturnState: SearchReturnState?
    @State private var searchStartedWithHiddenTabs = false
    @State private var tabBarHeight: CGFloat = 80
    @State private var hosts = SectionHosts()

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
            TabView(selection: Binding(
                get: { tabSelection },
                set: {
                    traceNavigation("selection.writeback requested=\(tabName($0))")
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
                        .vesperNavigationBarMaterial()
                        .searchable(text: $searchQuery, isPresented: Binding(
                            get: { searchInputActive },
                            set: { active in
                                guard !active || isSearchPresented else {
                                    traceNavigation("search.activationIgnored")
                                    return
                                }
                                searchInputActive = active
                            }
                        ), prompt: "搜索当前媒体来源")
                        .searchFocused($searchFocused)
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
            .background(.clear)
            .toolbarBackground(.ultraThinMaterial, for: .tabBar)
            .background(MultifunctionGestures(
                tap: { performGesture("tap") },
                longPress: { performGesture("longPress") },
                enabled: !isSearchPresented,
                trace: { event in traceNavigation(event) },
                reportHeight: { height in
                    if tabBarHeight != height { tabBarHeight = height }
                }
            ))

            // This sibling owns the ordinary pages, independently of TabView.
            // Reserve the native bar's measured area so it remains interactive.
            ContentHost(
                hosts: hosts,
                currentPage: currentPage,
                openSources: openSources,
                isSearchPresented: isSearchPresented,
                showPrimaryTabs: showPrimaryTabs,
                searchQuery: searchQuery
            ) {
                guard multifunctionEnabled, !isSearchPresented, !isPreparingSearch else { return }
                collapsePrimaryTabs()
            }
                .ignoresSafeArea(edges: .top)
                .padding(.bottom, tabBarHeight + 24)
                .clipped()

        }
        .background(VesperTheme.background.ignoresSafeArea())
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
            traceNavigation("search.tabSelected")
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
        .onChange(of: tabSelection) { old, new in
            traceNavigation("selection.onChange old=\(tabName(old))", selection: new)
        }
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

    private func traceNavigation(_ event: String, selection: NavigationTab? = nil) {
        let selected = selection ?? tabSelection
        let selectedName = tabName(selected)
        AppLog.trace("navigation.trace.\(event)", detail: "uptime=\(ProcessInfo.processInfo.systemUptime) selection=\(selectedName) isSearchPresented=\(isSearchPresented) tabGroupVisible=\(showPrimaryTabs) currentPage=\(currentPage.rawValue)")
    }

    private func tabName(_ tab: NavigationTab) -> String {
        switch tab {
        case let .section(section): return section.rawValue
        case .multifunction: return "multifunction"
        }
    }

    private var primaryTabs: some TabContent<NavigationTab> {
        TabSection("主要功能") {
            ForEach(enabledSections) { section in
                Tab(section.title, systemImage: section.symbol, value: NavigationTab.section(section)) {
                    Color.clear
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
        AppLog.info("navigation.selected.\(section.rawValue)", category: .navigation)
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

    private func openSources() {
        currentPage = .sources
        isSearchPresented = false
        synchronizeTabSelection()
    }

    private func collapsePrimaryTabs() {
        guard multifunctionEnabled, !isSearchPresented, !isPreparingSearch, collapseTask == nil else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            searchFocused = false
            searchInputActive = false
        }
        guard hasPreparedSearchControl else {
            finishCollapsingPrimaryTabs()
            return
        }
        let token = UUID()
        collapseToken = token
        traceNavigation("collapse.inputCleared")
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
                traceNavigation("collapse.searchContainerRemoved")
                try await Task.sleep(for: .milliseconds(0))
                guard !Task.isCancelled else { return }
                finishCollapsingPrimaryTabs()
                traceNavigation("collapse.groupHidden")
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
        traceNavigation("search.prepare startedHidden=\(searchStartedWithHiddenTabs)")
        synchronizeTabSelection()
        AppLog.info("navigation.search.opened", category: .navigation)
    }

    private func activateSearchInput() {
        // The Search Tab owns the native search control; ContentHost owns results.
        guard isSearchPresented else { return }
        searchInputActive = true
        searchFocused = true
        AppLog.info("navigation.search.manuallyActivated", category: .navigation)
    }

    private func closeSearch() {
        guard isSearchPresented || isPreparingSearch else { return }
        isPreparingSearch = false
        searchFocused = false
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
        AppLog.info("navigation.search.closed", category: .navigation)
    }

}

/// Four persistent hosts, each with its own NavigationStack.
@MainActor
private final class SectionHosts {
    private var controllers: [AppSection: UIHostingController<AnyView>] = [:]

    func controller(for section: AppSection, openSources: @escaping () -> Void) -> UIHostingController<AnyView> {
        if let controller = controllers[section] { return controller }
        let page: AnyView
        switch section {
        case .media: page = AnyView(NavigationStack { MediaView(openSources: openSources) }.background(VesperTheme.background.ignoresSafeArea()))
        case .sources: page = AnyView(NavigationStack { SourcesView() }.background(VesperTheme.background.ignoresSafeArea()))
        case .history: page = AnyView(NavigationStack { HistoryView() }.background(VesperTheme.background.ignoresSafeArea()))
        case .settings: page = AnyView(NavigationStack { SettingsView() }.background(VesperTheme.background.ignoresSafeArea()))
        }
        let controller = UIHostingController(rootView: page)
        controller.view.backgroundColor = .clear
        controllers[section] = controller
        return controller
    }
}

private struct ContentHost: UIViewControllerRepresentable {
    let hosts: SectionHosts
    let currentPage: AppSection
    let openSources: () -> Void
    let isSearchPresented: Bool
    let showPrimaryTabs: Bool
    let searchQuery: String
    let contentTapped: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(contentTapped: contentTapped) }

    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        container.view.backgroundColor = .clear
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
            let host = hosts.controller(for: section, openSources: openSources)
            container.addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            container.view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
            ])
            host.view.isHidden = isSearchPresented || section != currentPage
            host.didMove(toParent: container)
        }
        let searchHost = UIHostingController(rootView: AnyView(
            SearchPage(query: searchQuery)
        ))
        searchHost.view.accessibilityIdentifier = "search-page-host"
        searchHost.view.backgroundColor = .clear
        container.addChild(searchHost)
        searchHost.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(searchHost.view)
        NSLayoutConstraint.activate([
            searchHost.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            searchHost.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            searchHost.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            searchHost.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
        ])
        searchHost.view.isHidden = !isSearchPresented
        searchHost.didMove(toParent: container)
        context.coordinator.isSearchPresented = isSearchPresented
        context.coordinator.showPrimaryTabs = showPrimaryTabs
        return container
    }

    func updateUIViewController(_ container: UIViewController, context: Context) {
        context.coordinator.contentTapped = contentTapped
        context.coordinator.isSearchPresented = isSearchPresented
        context.coordinator.showPrimaryTabs = showPrimaryTabs
        for section in AppSection.allCases {
            let host = hosts.controller(for: section, openSources: openSources)
            host.view.isHidden = isSearchPresented || section != currentPage
            host.view.accessibilityElementsHidden = isSearchPresented || section != currentPage
        }
        if let searchHost = container.children.first(where: { $0 is UIHostingController<AnyView> && $0.view.accessibilityIdentifier == "search-page-host" }) as? UIHostingController<AnyView> {
            searchHost.rootView = AnyView(SearchPage(query: searchQuery))
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
    let trace: (String) -> Void
    let reportHeight: (CGFloat) -> Void

    func makeUIViewController(context: Context) -> GestureController {
        GestureController(tap: tap, longPress: longPress, reportHeight: reportHeight)
    }

    func updateUIViewController(_ controller: GestureController, context: Context) {
        controller.trace = trace
        controller.tapAction = tap
        controller.longPressAction = longPress
        controller.reportHeight = reportHeight
        controller.gesturesEnabled = enabled
        controller.installWhenReady()
    }

    static func dismantleUIViewController(_ controller: GestureController, coordinator: ()) {
        controller.uninstall()
    }

    final class GestureController: UIViewController, UIGestureRecognizerDelegate {
        var tapAction: () -> Void
        var longPressAction: () -> Void
        var reportHeight: (CGFloat) -> Void
        var gesturesEnabled = true
        var trace: (String) -> Void = { _ in }
        private var lastNativeSelection: String?
        private var touchSequence = 0
        private var lastTouchTime: TimeInterval?
        private weak var installedBar: UITabBar?
        private lazy var tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
        private lazy var pressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))

        init(tap: @escaping () -> Void, longPress: @escaping () -> Void, reportHeight: @escaping (CGFloat) -> Void) {
            self.reportHeight = reportHeight
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
            controller.tabBar.backgroundColor = .clear
            controller.tabBar.isTranslucent = true
            for child in controller.viewControllers ?? [] {
                child.view.backgroundColor = .clear
                child.view.isOpaque = false
            }
            let nativeSelection = "index=\(controller.selectedIndex) tab=\(controller.selectedTab?.identifier ?? "none") item=\(controller.tabBar.selectedItem?.title ?? "none")"
            if nativeSelection != lastNativeSelection {
                lastNativeSelection = nativeSelection
                let elapsed = lastTouchTime.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) } ?? -1
                trace("UIKit.selection touchID=\(touchSequence) sinceTouchMs=\(elapsed) \(nativeSelection)")
            }
            for tab in controller.tabs {
                if let search = tab as? UISearchTab {
                    // App gestures own search activation, including when this tab is
                    // selected to keep the primary group collapsed.
                    search.automaticallyActivatesSearch = false

                }
            }
            let bar = controller.tabBar
            let height = max(0, bar.bounds.height - controller.view.safeAreaInsets.bottom)
            if height > 0 {
                DispatchQueue.main.async { [weak self] in self?.reportHeight(height) }
            }
            guard installedBar !== bar else { return }
            uninstall()
            installedBar = bar
            tapRecognizer.delegate = self
            pressRecognizer.delegate = self
            tapRecognizer.cancelsTouchesInView = true
            pressRecognizer.cancelsTouchesInView = true
            tapRecognizer.require(toFail: pressRecognizer)
            bar.addGestureRecognizer(tapRecognizer)
            bar.addGestureRecognizer(pressRecognizer)
        }

        private func findTabController(in controller: UIViewController) -> UITabBarController? {
            if let tabs = controller as? UITabBarController { return tabs }
            for child in controller.children {
                if let tabs = findTabController(in: child) { return tabs }
            }
            return nil
        }

        func uninstall() {
            installedBar?.removeGestureRecognizer(tapRecognizer)
            installedBar?.removeGestureRecognizer(pressRecognizer)
            installedBar = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard gesturesEnabled, let bar = installedBar else { return false }
            // The independent search-role item occupies the trailing platter.
            // Use the public item's accessibility frame when UIKit supplies it.
            let hitsItem: Bool
            if let frame = bar.items?.last?.accessibilityFrame, !frame.isEmpty {
                hitsItem = frame.contains(touch.location(in: nil))
            } else {
                hitsItem = touch.location(in: bar).x >= bar.bounds.width - 88
            }
            if hitsItem, gestureRecognizer === tapRecognizer {
                touchSequence += 1
                lastTouchTime = ProcessInfo.processInfo.systemUptime
                trace("SearchTab.touch.received id=\(touchSequence) cancelsTouches=\(tapRecognizer.cancelsTouchesInView) nativeItem=\(bar.selectedItem?.title ?? "none") touchTime=\(touch.timestamp)")
            }
            return hitsItem
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        @objc private func tapped() {
            trace("SearchTab.tap.recognized id=\(touchSequence) nativeItem=\(installedBar?.selectedItem?.title ?? "none")")
            tapAction()
            trace("SearchTab.tap.actionReturned id=\(touchSequence)")
            let sequence = touchSequence
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.trace("SearchTab.tap.nextRunLoop id=\(sequence) nativeItem=\(self.installedBar?.selectedItem?.title ?? "none")")
            }
        }
        @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                trace("SearchTab.longPress.thresholdReached id=\(touchSequence)")
            case .ended:
                trace("SearchTab.longPress.released id=\(touchSequence)")
                longPressAction()
                trace("SearchTab.longPress.actionReturned id=\(touchSequence)")
            case .cancelled, .failed:
                trace("SearchTab.longPress.cancelled id=\(touchSequence)")
            default:
                break
            }
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
            .background(VesperTheme.background.ignoresSafeArea())
            .vesperNavigationBarMaterial()
        }
    }
}
