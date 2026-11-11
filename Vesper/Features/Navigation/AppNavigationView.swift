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

/// Each destination owns its controller. UISearchTab is only a search destination;
/// selecting a regular tab never selects Search as a side effect.
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
        controller.delegate = coordinator
        coordinator.controller = controller
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        controller.tabBar.standardAppearance = appearance
        controller.tabBar.scrollEdgeAppearance = appearance
        controller.tabBar.tintColor = UIColor(named: "VesperAccent")
        let press = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.longPress(_:)))
        press.delaysTouchesBegan = true
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

        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        let ordered = saved + AppSection.allCases.filter { !saved.contains($0) }
        let excluded = Set(hidden.split(separator: ",").map(String.init))
        let enabled = ordered.filter { $0 == .settings || !excluded.contains($0.rawValue) }
        let visible: [AppSection]
        if allowsHidingTabBar && !isExpanded {
            visible = enabled.contains(selection) ? [selection] : [.settings]
        } else {
            visible = enabled
        }
        let tabs = visible.compactMap { coordinator.destinations[$0] } + [coordinator.searchTab]
        if controller.tabs.map(\.identifier) != tabs.map(\.identifier) {
            controller.setTabs(tabs, animated: false)
        }
        if !coordinator.isSearching,
           let selected = coordinator.destinations[selection], controller.selectedTab !== selected {
            controller.selectedTab = selected
        }
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate, UIGestureRecognizerDelegate, UISearchResultsUpdating, UISearchControllerDelegate {
        var parent: SearchTabContainer
        weak var controller: UITabBarController?
        var isSearching = false
        let results = UIHostingController(rootView: AnyView(EmptyView()))
        lazy var searchController = UISearchController(searchResultsController: results)
        lazy var searchPage: UIViewController = {
            let page = UIViewController()
            page.title = nil
            page.view.backgroundColor = .systemBackground
            page.navigationItem.searchController = searchController
            page.navigationItem.hidesSearchBarWhenScrolling = false
            page.definesPresentationContext = true
            return page
        }()
        lazy var searchNavigation = UINavigationController(rootViewController: searchPage)
        lazy var searchTab: UISearchTab = {
            let tab = UISearchTab { [weak self] _ in
                self?.searchNavigation ?? UIViewController()
            }
            tab.image = UIImage(systemName: "square.grid.2x2")
            tab.automaticallyActivatesSearch = true
            return tab
        }()
        lazy var hosts: [AppSection: UIHostingController<AnyView>] = Dictionary(uniqueKeysWithValues: AppSection.allCases.map { section in
            (section, UIHostingController(rootView: AnyView(EmptyView())))
        })
        lazy var destinations: [AppSection: UITab] = Dictionary(uniqueKeysWithValues: AppSection.allCases.map { section in
            (section, UITab(title: section.title, image: UIImage(systemName: section.symbol), identifier: section.rawValue) { [weak self] _ in
                self?.hosts[section] ?? UIViewController()
            })
        })

        init(parent: SearchTabContainer) {
            self.parent = parent
            super.init()
            searchController.searchResultsUpdater = self
            searchController.delegate = self
            searchController.searchBar.placeholder = "搜索当前媒体来源"
            updateSearchResults(for: searchController)
        }

        func tabBarController(_ tabBarController: UITabBarController, didSelectTab tab: UITab) {
            guard let section = AppSection(rawValue: tab.identifier) else { return }
            parent.selection = section
            AppLog.info("navigation.selected.\(section.rawValue)", category: .navigation)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let bar = controller?.tabBar else { return false }
            let point = gestureRecognizer.location(in: bar)
            let searchFrame = searchTab.viewController?.tabBarItem.accessibilityFrame ?? .zero
            if !searchFrame.isEmpty {
                return searchFrame.contains(bar.convert(point, to: nil))
            }
            return point.x >= bar.bounds.width - 88
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, !isSearching, parent.allowsHidingTabBar else { return }
            parent.isExpanded.toggle()
            AppLog.info("navigation.tabs.long_press_toggled", category: .navigation)
        }

        func willPresentSearchController(_ searchController: UISearchController) {
            isSearching = true
            parent.isExpanded = false
        }

        func didDismissSearchController(_ searchController: UISearchController) {
            isSearching = false
        }

        func updateSearchResults(for searchController: UISearchController) {
            results.rootView = AnyView(ContentUnavailableView(
                "暂无可搜索内容", systemImage: "magnifyingglass",
                description: Text("搜索范围为当前媒体来源。真实媒体来源尚未接入，暂时无法返回结果。")
            ))
        }
    }
}
