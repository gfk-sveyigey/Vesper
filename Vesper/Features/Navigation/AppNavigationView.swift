import SwiftUI
import UIKit

struct AppNavigationView: View {
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("navigation.allowsHidingTabBar") private var allowsHidingTabBar = true
    @State private var selection: AppSection = .media
    @State private var isExpanded = false
    @State private var mediaPath = NavigationPath()
    @State private var sourcesPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    var body: some View {
        SearchTabContainer(
            selection: $selection,
            isExpanded: $isExpanded,
            order: order,
            hidden: hidden,
            allowsHidingTabBar: allowsHidingTabBar,
            pages: pages
        )
        .ignoresSafeArea(edges: .bottom)
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
    let order: String
    let hidden: String
    let allowsHidingTabBar: Bool
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

        let press = UILongPressGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.longPress(_:))
        )
        press.delaysTouchesBegan = true
        press.cancelsTouchesInView = true
        press.delegate = coordinator
        controller.tabBar.addGestureRecognizer(press)
        return controller
    }

    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.contentHost.rootView = pages[selection] ?? AnyView(EmptyView())

        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        let ordered = saved + AppSection.allCases.filter { !saved.contains($0) }
        let excluded = Set(hidden.split(separator: ",").map(String.init))
        let enabled = ordered.filter { $0 == .settings || !excluded.contains($0.rawValue) }
        let shouldShowGroup = !allowsHidingTabBar || isExpanded || coordinator.isSearching
        let destinations = shouldShowGroup
            ? enabled.compactMap { coordinator.destinations[$0] }
            : []
        let tabs = destinations + [coordinator.searchTab]

        if controller.tabs.map(\.identifier) != tabs.map(\.identifier) {
            controller.setTabs(tabs, animated: false)
        }

        if !coordinator.isSearching, controller.selectedTab !== coordinator.searchTab {
            controller.selectedTab = coordinator.searchTab
        }
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate, UIGestureRecognizerDelegate,
        UISearchResultsUpdating, UISearchControllerDelegate {
        var parent: SearchTabContainer
        weak var controller: UITabBarController?
        var isSearching = false

        let contentHost = UIHostingController(rootView: AnyView(EmptyView()))
        let results = UIHostingController(rootView: AnyView(EmptyView()))
        lazy var searchController = UISearchController(searchResultsController: results)

        lazy var homeController: UIViewController = {
            let viewController = UIViewController()
            viewController.view.backgroundColor = .systemBackground
            viewController.addChild(contentHost)
            contentHost.view.translatesAutoresizingMaskIntoConstraints = false
            viewController.view.addSubview(contentHost.view)
            NSLayoutConstraint.activate([
                contentHost.view.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
                contentHost.view.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
                contentHost.view.topAnchor.constraint(equalTo: viewController.view.topAnchor),
                contentHost.view.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor)
            ])
            contentHost.didMove(toParent: viewController)
            viewController.navigationItem.searchController = searchController
            viewController.navigationItem.hidesSearchBarWhenScrolling = false
            viewController.definesPresentationContext = true
            return viewController
        }()

        lazy var searchNavigation = UINavigationController(rootViewController: homeController)

        lazy var searchTab: UISearchTab = {
            let tab = UISearchTab { [weak self] _ in
                self?.searchNavigation ?? UIViewController()
            }
            tab.image = UIImage(systemName: "square.grid.2x2")
            tab.automaticallyActivatesSearch = false
            return tab
        }()

        lazy var destinations: [AppSection: UITab] = Dictionary(
            uniqueKeysWithValues: AppSection.allCases.map { section in
                (section, UITab(
                    title: section.title,
                    image: UIImage(systemName: section.symbol),
                    identifier: section.rawValue
                ) { [weak self] _ in
                    guard let self else { return UIViewController() }
                    return UIHostingController(rootView: self.parent.pages[section] ?? AnyView(EmptyView()))
                })
            }
        )

        init(parent: SearchTabContainer) {
            self.parent = parent
            super.init()
            searchController.searchResultsUpdater = self
            searchController.delegate = self
            searchController.searchBar.placeholder = "搜索当前媒体来源"
            updateSearchResults(for: searchController)
        }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            guard tab === searchTab else { return true }
            guard parent.allowsHidingTabBar else { return false }
            parent.isExpanded.toggle()
            AppLog.info("navigation.tabs.toggled", category: .navigation)
            return false
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelectTab tab: UITab) {
            guard let section = AppSection(rawValue: tab.identifier) else { return }
            parent.selection = section
            parent.isExpanded = false
            AppLog.info("navigation.selected.\(section.rawValue)", category: .navigation)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let tabBar = controller?.tabBar else { return false }
            let frame = searchTab.viewController?.tabBarItem.accessibilityFrame ?? .zero
            let point = gestureRecognizer.location(in: tabBar)
            if !frame.isEmpty {
                return frame.contains(tabBar.convert(point, to: nil))
            }
            return point.x >= tabBar.bounds.width - 88
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  parent.allowsHidingTabBar,
                  let controller else { return }

            isSearching = true
            parent.isExpanded = true
            controller.selectedTab = searchTab
            searchController.isActive = true
            AppLog.info("navigation.search.long_press_opened", category: .navigation)

            DispatchQueue.main.async { [weak self] in
                self?.searchController.searchBar.searchTextField.becomeFirstResponder()
            }
        }

        func willPresentSearchController(_ searchController: UISearchController) {
            isSearching = true
            parent.isExpanded = true
            DispatchQueue.main.async { [weak searchController] in
                searchController?.searchBar.searchTextField.becomeFirstResponder()
            }
        }

        func didDismissSearchController(_ searchController: UISearchController) {
            isSearching = false
        }

        func updateSearchResults(for searchController: UISearchController) {
            results.rootView = AnyView(ContentUnavailableView(
                "暂无可搜索内容",
                systemImage: "magnifyingglass",
                description: Text("搜索范围为当前媒体来源。真实媒体来源尚未接入，暂时无法返回结果。")
            ))
        }
    }
}
