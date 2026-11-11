import SwiftUI
import UIKit

struct AppNavigationView: View {
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @State private var selection: AppSection = .media
    @State private var isExpanded = false
    @State private var mediaPath = NavigationPath()
    @State private var sourcesPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    var body: some View {
        SearchTabContainer(
            selection: $selection, isExpanded: $isExpanded,
            order: order, hidden: hidden, content: AnyView(selectedContent)
        )
        .ignoresSafeArea(edges: .bottom)
    }

    @ViewBuilder private var selectedContent: some View {
        Group {
            switch selection {
            case .media:
                NavigationStack(path: $mediaPath) {
                    MediaView(openSources: { selection = .sources })
                }
            case .sources:
                NavigationStack(path: $sourcesPath) { SourcesView() }
            case .history:
                NavigationStack(path: $historyPath) { HistoryView() }
            case .settings:
                NavigationStack(path: $settingsPath) { SettingsView() }
            }
        }
        .simultaneousGesture(TapGesture().onEnded { isExpanded = false })
        .background(Color("VesperBackground"))
    }
}

/// Experimental integration: Search retains its native role; a tap is an action,
/// while a long press explicitly selects the Search destination.
private struct SearchTabContainer: UIViewControllerRepresentable {
    @Binding var selection: AppSection
    @Binding var isExpanded: Bool
    let order: String
    let hidden: String
    let content: AnyView

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
        coordinator.host.rootView = content
        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        let ordered = saved + AppSection.allCases.filter { !saved.contains($0) }
        let excluded = Set(hidden.split(separator: ",").map(String.init))
        let destinations = isExpanded && !coordinator.isSearching ? ordered.filter { $0 == .settings || !excluded.contains($0.rawValue) }
            .compactMap { coordinator.destinations[$0] } : []
        let tabs = destinations + [coordinator.searchTab]
        if controller.tabs.map(\.identifier) != tabs.map(\.identifier) {
            controller.setTabs(tabs, animated: false)
        }
        coordinator.searchTab.viewController?.tabBarItem.accessibilityLabel = "多功能"
        coordinator.searchTab.viewController?.tabBarItem.accessibilityHint = "轻点展开标签，长按搜索"
        coordinator.searchTab.viewController?.tabBarItem.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "打开搜索", target: coordinator, selector: #selector(Coordinator.openSearchAccessibility))
        ]
        if !coordinator.isSearching {
            // The persistent Search host also displays the current page while collapsed.
            controller.selectedTab = coordinator.searchTab
        }
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate, UIGestureRecognizerDelegate, UISearchResultsUpdating, UISearchBarDelegate {
        var parent: SearchTabContainer
        weak var controller: UITabBarController?
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        let searchPage = UIViewController()
        let results = UIHostingController(rootView: AnyView(EmptyView()))
        var isSearching = false
        var isEditingSearch = false
        lazy var searchController = UISearchController(searchResultsController: results)
        lazy var searchNavigation: UINavigationController = {
            let navigation = UINavigationController(rootViewController: host)
            navigation.setNavigationBarHidden(true, animated: false)
            return navigation
        }()
        lazy var searchTab: UISearchTab = {
            let tab = UISearchTab { [weak self] _ in
                guard let self else { return UIViewController() }
                return self.searchNavigation
            }
            tab.image = UIImage(systemName: "square.grid.2x2")
            tab.automaticallyActivatesSearch = true
            return tab
        }()
        lazy var destinations: [AppSection: UITab] = Dictionary(uniqueKeysWithValues: AppSection.allCases.map { section in
            (section, UITab(title: section.title, image: UIImage(systemName: section.symbol), identifier: section.rawValue) { _ in UIViewController() })
        })

        init(parent: SearchTabContainer) {
            self.parent = parent
            super.init()
            searchPage.title = nil
            searchPage.view.backgroundColor = .systemBackground
            searchController.searchResultsUpdater = self
            searchController.searchBar.delegate = self
            searchController.automaticallyShowsCancelButton = true
            searchController.searchBar.showsCancelButton = true
            searchController.searchBar.placeholder = "搜索当前媒体来源"
            searchPage.navigationItem.searchController = searchController
            searchPage.navigationItem.hidesSearchBarWhenScrolling = false
            searchPage.definesPresentationContext = true
            searchPage.navigationItem.leftBarButtonItem = nil
            updateSearchResults(for: searchController)
        }

        func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            if tab === searchTab {
                if isSearching { return true }
                parent.isExpanded.toggle()
            } else if let section = AppSection(rawValue: tab.identifier) {
                parent.selection = section
                AppLog.info("navigation.selected.\(section.rawValue)", category: .navigation)
            }
            return false
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let bar = controller?.tabBar else { return false }
            // Search can have a separate system frame. Prefer the native item's
            // accessibility geometry, never UIKit private class names or KVC.
            let frame = searchTab.viewController?.tabBarItem.accessibilityFrame ?? .zero
            let point = gestureRecognizer.location(in: bar)
            if !frame.isEmpty { return frame.contains(bar.convert(point, to: nil)) }
            return point.x >= bar.bounds.width - 88
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let controller else { return }
            openSearch(in: controller)
        }

        @objc func openSearchAccessibility() -> Bool {
            guard let controller else { return false }
            openSearch(in: controller)
            return true
        }

        private func openSearch(in controller: UITabBarController) {
            isSearching = true
            parent.isExpanded = false
            // Remove destination tabs before activating Search, not on the next
            // SwiftUI update, so no stale group remains during the transition.
            controller.setTabs([searchTab], animated: false)
            searchNavigation.setNavigationBarHidden(false, animated: false)
            searchNavigation.setViewControllers([searchPage], animated: false)
            controller.selectedTab = searchTab
            searchController.isActive = true
            searchController.searchBar.showsCancelButton = true
            AppLog.info("navigation.search.opened", category: .navigation)
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            isEditingSearch = true
            searchBar.showsCancelButton = true
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            isEditingSearch = false
            if isSearching { searchBar.setShowsCancelButton(true, animated: false) }
        }

        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            if isEditingSearch || searchBar.searchTextField.isFirstResponder {
                searchBar.resignFirstResponder()
                searchBar.searchTextField.resignFirstResponder()
                isEditingSearch = false
                searchBar.showsCancelButton = true
            } else {
                closeSearch()
            }
        }

        func closeSearch() {
            searchController.isActive = false
            isSearching = false
            isEditingSearch = false
            searchNavigation.setViewControllers([host], animated: false)
            searchNavigation.setNavigationBarHidden(true, animated: false)
            controller?.selectedTab = searchTab
        }

        func updateSearchResults(for searchController: UISearchController) {
            results.rootView = AnyView(ContentUnavailableView(
                "暂无可搜索内容", systemImage: "magnifyingglass",
                description: Text("搜索范围为当前媒体来源。真实媒体来源尚未接入，暂时无法返回结果。")
            ))
        }
    }
}
