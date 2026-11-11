import SwiftUI
import UIKit

struct AppNavigationView: View {
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("navigation.allowsHidingTabBar") private var allowsHidingTabBar = true
    @AppStorage("navigation.gestureOrder") private var gestures = "tap,longPress"
    @AppStorage("navigation.actionOrder") private var actions = "tabs,search"
    @State private var selection: AppSection = .media
    @State private var isExpanded = false
    @State private var isSearchPresented = false
    @State private var mediaPath = NavigationPath()
    @State private var sourcesPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    var body: some View {
        SearchTabContainer(
            selection: $selection,
            isExpanded: $isExpanded,
            isSearchPresented: $isSearchPresented,
            order: order,
            hidden: hidden,
            allowsHidingTabBar: allowsHidingTabBar,
            gestures: gestures, actions: actions,
            pages: pages
        )
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: selection) { _, _ in
            isSearchPresented = false
        }
    }

    private var pages: [AppSection: AnyView] {
        [
            .media: AnyView(NavigationStack(path: $mediaPath) {
                MediaView(openSources: { selection = .sources })
            }),
            .sources: AnyView(NavigationStack(path: $sourcesPath) { SourcesView() }),
            .history: AnyView(NavigationStack(path: $historyPath) { HistoryView() }),
            .settings: AnyView(NavigationStack(path: $settingsPath) { SettingsView() })
        ]
    }

}

private struct SearchTabContainer: UIViewControllerRepresentable {
    @Binding var selection: AppSection
    @Binding var isExpanded: Bool
    @Binding var isSearchPresented: Bool
    let order: String
    let hidden: String
    let allowsHidingTabBar: Bool
    let gestures: String
    let actions: String
    let pages: [AppSection: AnyView]

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        let coordinator = context.coordinator
        coordinator.controller = controller
        controller.delegate = coordinator

        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        controller.tabBar.standardAppearance = appearance
        controller.tabBar.scrollEdgeAppearance = appearance
        controller.tabBar.tintColor = UIColor(named: "VesperAccent")

        let press = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.longPress(_:)))
        press.delaysTouchesBegan = true
        press.cancelsTouchesInView = true
        press.delegate = coordinator
        controller.tabBar.addGestureRecognizer(press)
        return controller
    }

    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        for section in AppSection.allCases {
            coordinator.hosts[section]?.rootView = pages[section] ?? AnyView(EmptyView())
        }
        coordinator.searchHost.rootView = AnyView(SearchPage(isPresented: $isSearchPresented))

        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        let ordered = saved + AppSection.allCases.filter { !saved.contains($0) }
        let excluded = Set(hidden.split(separator: ",").map(String.init))
        let enabled = ordered.filter { $0 == .settings || !excluded.contains($0.rawValue) }
        let showGroup = !allowsHidingTabBar || isExpanded
        let destinationTabs = showGroup ? enabled.compactMap { coordinator.destinations[$0] } : []
        let tabs = destinationTabs + [coordinator.multifunctionTab]

        if controller.tabs.map(\.identifier) != tabs.map(\.identifier) {
            controller.setTabs(tabs, animated: false)
        }

        let desiredTab = showGroup && !isSearchPresented
            ? coordinator.destinations[selection]
            : coordinator.multifunctionTab
        if let desiredTab, tabs.contains(where: { $0 === desiredTab }),
           controller.selectedTab !== desiredTab {
            controller.selectedTab = desiredTab
        }

        // A section owns exactly one NavigationStack, regardless of tab visibility.
        // Move its host between containers instead of creating a second stack
        // with the same NavigationPath binding.
        if isSearchPresented {
            coordinator.embed(coordinator.searchHost, in: coordinator.contentHost)
        } else if let host = coordinator.hosts[selection] {
            let container = showGroup && enabled.contains(selection)
                ? coordinator.destinationContainers[selection] ?? coordinator.contentHost
                : coordinator.contentHost
            coordinator.embed(host, in: container)
        }
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate, UIGestureRecognizerDelegate {
        var parent: SearchTabContainer
        weak var controller: UITabBarController?
        let contentHost = UIViewController()
        let searchHost = UIHostingController(rootView: AnyView(EmptyView()))
        let destinationContainers: [AppSection: UIViewController] = Dictionary(
            uniqueKeysWithValues: AppSection.allCases.map { ($0, UIViewController()) }
        )

        func embed(_ child: UIViewController, in container: UIViewController) {
            guard child.parent !== container else { return }
            for previous in container.children {
                previous.willMove(toParent: nil)
                previous.view.removeFromSuperview()
                previous.removeFromParent()
            }
            child.willMove(toParent: nil)
            child.viewIfLoaded?.removeFromSuperview()
            child.removeFromParent()
            container.addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            container.view.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
                child.view.topAnchor.constraint(equalTo: container.view.topAnchor),
                child.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
            ])
            child.didMove(toParent: container)
        }

        lazy var multifunctionTab: UISearchTab = {
            let tab = UISearchTab { [weak self] _ in
                self?.contentHost ?? UIViewController()
            }
            tab.image = UIImage(systemName: "square.grid.2x2")
            tab.automaticallyActivatesSearch = false
            return tab
        }()

        lazy var hosts: [AppSection: UIHostingController<AnyView>] = Dictionary(
            uniqueKeysWithValues: AppSection.allCases.map { section in
                (section, UIHostingController(rootView: AnyView(EmptyView())))
            }
        )

        lazy var destinations: [AppSection: UITab] = Dictionary(
            uniqueKeysWithValues: AppSection.allCases.map { section in
                (section, UITab(
                    title: section.title,
                    image: UIImage(systemName: section.symbol),
                    identifier: section.rawValue
                ) { [weak self] _ in
                    guard let self else { return UIViewController() }
                    return self.destinationContainers[section] ?? UIViewController()
                })
            }
        )

        init(parent: SearchTabContainer) {
            self.parent = parent
        }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            guard tab === multifunctionTab else {
                closeSearch()
                return true
            }
            performGesture("tap")
            return false
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelectTab tab: UITab, previousTab: UITab?) {
            guard let section = AppSection(rawValue: tab.identifier) else { return }
            closeSearch()
            parent.selection = section
            parent.isExpanded = false
            AppLog.info("navigation.selected.\(section.rawValue)", category: .navigation)
        }

        private func closeSearch() {
            guard parent.isSearchPresented else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { parent.isSearchPresented = false }
            UIView.performWithoutAnimation {
                controller?.view.endEditing(true)
                searchHost.viewIfLoaded?.endEditing(true)
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let tabBar = controller?.tabBar else { return false }
            let frame = multifunctionTab.viewController?.tabBarItem.accessibilityFrame ?? .zero
            let point = gestureRecognizer.location(in: tabBar)
            if !frame.isEmpty {
                return frame.contains(tabBar.convert(point, to: nil))
            }
            return point.x >= tabBar.bounds.width - 88
        }

        private func performGesture(_ gesture: String) {
            let gestures = parent.gestures.split(separator: ",").map(String.init)
            let actions = parent.actions.split(separator: ",").map(String.init)
            guard let index = gestures.firstIndex(of: gesture), actions.indices.contains(index) else { return }
            if actions[index] == "tabs" {
                if parent.allowsHidingTabBar { parent.isExpanded.toggle() }
            } else {
                if parent.allowsHidingTabBar { parent.isExpanded = true }
                parent.isSearchPresented = true
            }
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            performGesture("longPress")
        }
    }
}

private struct SearchPage: View {
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var inputActive = false

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                query.isEmpty ? "搜索媒体" : "暂无搜索结果",
                systemImage: "magnifyingglass",
                description: Text("搜索范围为当前媒体来源。真实媒体来源尚未接入。")
            )
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .searchable(text: $query, isPresented: $inputActive, prompt: "搜索当前媒体来源")
        .searchFocused($searchFocused)
        .task {
            await Task.yield()
            guard !Task.isCancelled, isPresented else { return }
            inputActive = true
            searchFocused = true
        }
        .onChange(of: isPresented) { _, presented in
            if !presented {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    inputActive = false
                    searchFocused = false
                }
            }
        }
        .onDisappear {
            inputActive = false
            searchFocused = false
        }
    }
}
