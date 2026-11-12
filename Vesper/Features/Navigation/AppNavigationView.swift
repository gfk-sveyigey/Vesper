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
    @State private var currentPage: AppSection = .media
    @State private var tabSelection: NavigationTab = .section(.media)
    @State private var isExpanded = false
    @State private var didInitializeNavigation = false
    @State private var isSearchPresented = false
    @State private var isPreparingSearch = false
    @State private var searchQuery = ""
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
            TabView(selection: Binding(
                get: { tabSelection },
                set: { selectTab($0) }
            )) {
                primaryTabs
                Tab(isSearchPresented || !multifunctionEnabled ? "搜索" : "多功能",
                    systemImage: isSearchPresented || !multifunctionEnabled ? "magnifyingglass" : "square.grid.2x2",
                    value: NavigationTab.multifunction, role: .search) {
                    // Keep the search controller alive while UIKit completes
                    // its cancel/collapse transition.
                    SearchPage(query: searchQuery)
                }
            }
            .searchable(text: $searchQuery, prompt: "搜索当前媒体来源")
            .tabViewSearchActivation(!multifunctionEnabled || isSearchPresented ? .searchTabSelection : .automatic)
            .toolbarBackground(.hidden, for: .tabBar)
            .background(MultifunctionGestures(
                tap: { performGesture("tap") },
                longPress: { performGesture("longPress") },
                enabled: !isSearchPresented && !isPreparingSearch,
                searchMode: isSearchPresented || !multifunctionEnabled,
                reportHeight: { height in
                    if tabBarHeight != height { tabBarHeight = height }
                }
            ))

            // This sibling owns the ordinary pages, independently of TabView.
            // Reserve the native bar's measured area so it remains interactive.
            ContentHost(hosts: hosts, currentPage: currentPage, openSources: openSources) {
                guard multifunctionEnabled, !isSearchPresented, !isPreparingSearch else { return }
                isExpanded = false
                synchronizeTabSelection()
            }
                .padding(.bottom, tabBarHeight + 24)
                .clipped()
                .opacity(isSearchPresented ? 0 : 1)
                .allowsHitTesting(!isSearchPresented)
                .accessibilityHidden(isSearchPresented)

        }
        .tint(Color("VesperAccent"))
        .task(id: isPreparingSearch) {
            guard isPreparingSearch else { return }
            // The only timed delay: wait after requesting group expansion before
            // switching icon, selecting Search and presenting its page.
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch { return }
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
        .onChange(of: multifunctionEnabled) { _, enabled in
            if !enabled { isExpanded = true }
            synchronizeTabSelection()
        }
        .onChange(of: enabledSections) { _, _ in synchronizeTabSelection() }
        .onChange(of: isSearchPresented) { _, _ in synchronizeTabSelection() }

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
        if isSearchPresented || isPreparingSearch { closeSearch() }
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
            isExpanded.toggle()
        } else {
            openSearch()
        }
        synchronizeTabSelection()
    }

    private func openSearch() {
        guard !isSearchPresented, !isPreparingSearch else { return }
        searchQuery = ""
        searchStartedWithHiddenTabs = !showPrimaryTabs
        if searchStartedWithHiddenTabs {
            isExpanded = true
            isPreparingSearch = true
        } else {
            isSearchPresented = true
        }
        synchronizeTabSelection()
        AppLog.info("navigation.search.preparing", category: .navigation)
    }

    private func closeSearch() {
        guard isSearchPresented || isPreparingSearch else { return }
        isPreparingSearch = false
        isSearchPresented = false
        if searchStartedWithHiddenTabs { isExpanded = true }
        searchStartedWithHiddenTabs = false
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
        case .media: page = AnyView(NavigationStack { MediaView(openSources: openSources) })
        case .sources: page = AnyView(NavigationStack { SourcesView() })
        case .history: page = AnyView(NavigationStack { HistoryView() })
        case .settings: page = AnyView(NavigationStack { SettingsView() })
        }
        let controller = UIHostingController(rootView: page)
        controllers[section] = controller
        return controller
    }
}

private struct ContentHost: UIViewControllerRepresentable {
    let hosts: SectionHosts
    let currentPage: AppSection
    let openSources: () -> Void
    let contentTapped: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(contentTapped: contentTapped) }

    func makeUIViewController(context: Context) -> UIViewController {
        let container = UIViewController()
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = context.coordinator
        container.view.addGestureRecognizer(tap)
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
            host.view.isHidden = section != currentPage
            host.didMove(toParent: container)
        }
        return container
    }

    func updateUIViewController(_ container: UIViewController, context: Context) {
        context.coordinator.contentTapped = contentTapped
        for section in AppSection.allCases {
            let host = hosts.controller(for: section, openSources: openSources)
            host.view.isHidden = section != currentPage
            host.view.accessibilityElementsHidden = section != currentPage
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var contentTapped: () -> Void
        init(contentTapped: @escaping () -> Void) { self.contentTapped = contentTapped }

        @objc func tapped() {
            // Let the native control finish handling this touch before changing
            // tab visibility. Never cancel the original control's interaction.
            DispatchQueue.main.async { [weak self] in self?.contentTapped() }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }

}

/// Only bridges gestures on the system tab bar; does not replace its delegate,
/// tabs, selection, or access private UIKit view types.
private struct MultifunctionGestures: UIViewControllerRepresentable {
    let tap: () -> Void
    let longPress: () -> Void
    let enabled: Bool
    let searchMode: Bool
    let reportHeight: (CGFloat) -> Void

    func makeUIViewController(context: Context) -> GestureController {
        GestureController(tap: tap, longPress: longPress, reportHeight: reportHeight)
    }

    func updateUIViewController(_ controller: GestureController, context: Context) {
        controller.tapAction = tap
        controller.longPressAction = longPress
        controller.reportHeight = reportHeight
        controller.gesturesEnabled = enabled
        controller.searchMode = searchMode
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
        var searchMode = false
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
            for tab in controller.tabs {
                if let search = tab as? UISearchTab {
                    // SwiftUI tabViewSearchActivation owns activation and return behavior.
                    let image = UIImage(systemName: searchMode ? "magnifyingglass" : "square.grid.2x2")
                    if search.image != image { search.image = image }
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
            tapRecognizer.cancelsTouchesInView = false
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
            if let frame = bar.items?.last?.accessibilityFrame, !frame.isEmpty {
                return frame.contains(touch.location(in: nil))
            }
            return touch.location(in: bar).x >= bar.bounds.width - 88
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        @objc private func tapped() { tapAction() }
        @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began { longPressAction() }
        }
    }
}

/// Activation and cancellation are linked to selection by the system.
private struct SearchPage: View {
    let query: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                query.isEmpty ? "搜索媒体" : "暂无搜索结果",
                systemImage: "magnifyingglass",
                description: Text("搜索范围为当前媒体来源。真实媒体来源尚未接入。")
            )
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}
