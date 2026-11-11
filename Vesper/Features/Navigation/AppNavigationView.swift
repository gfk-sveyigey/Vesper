import SwiftUI
import UIKit

struct AppNavigationView: View {
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("navigation.allowsHidingTabBar") private var allowsHidingTabBar = true
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
            coordinator.hosts[section]?.rootView = dismissingContent(pages[section] ?? AnyView(EmptyView()))
        }
        coordinator.contentHost.rootView = isSearchPresented
            ? AnyView(SearchPage(isPresented: $isSearchPresented))
            : dismissingContent(pages[selection] ?? AnyView(EmptyView()))

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
    }

    private func dismissingContent(_ content: AnyView) -> AnyView {
        AnyView(content.simultaneousGesture(TapGesture().onEnded {
            if allowsHidingTabBar { isExpanded = false }
        }))
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate, UIGestureRecognizerDelegate {
        var parent: SearchTabContainer
        weak var controller: UITabBarController?
        let contentHost = UIHostingController(rootView: AnyView(EmptyView()))

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
                    return self.hosts[section] ?? UIViewController()
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
            guard parent.allowsHidingTabBar else { return false }
            parent.isExpanded.toggle()
            AppLog.info("navigation.tabs.toggled", category: .navigation)
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
            parent.isSearchPresented = false
            contentHost.viewIfLoaded?.endEditing(true)
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

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, parent.allowsHidingTabBar else { return }
            parent.isExpanded = true
            parent.isSearchPresented = true
            AppLog.info("navigation.search.long_press_opened", category: .navigation)
        }
    }
}

private struct SearchPage: View {
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                query.isEmpty ? "搜索媒体" : "暂无搜索结果",
                systemImage: "magnifyingglass",
                description: Text("搜索范围为当前媒体来源。真实媒体来源尚未接入。")
            )
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .searchable(text: $query, isPresented: $isPresented, prompt: "搜索当前媒体来源")
        .searchFocused($searchFocused)
        .onAppear {
            isPresented = true
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
    }
}
