import SwiftUI
import UIKit

struct AppNavigationView: View {
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("navigation.allowsHidingTabBar") private var allowsHidingTabBar = true
    @State private var selection: AppSection = .media
    @State private var isExpanded = false
    @State private var isShowingSearch = false
    @State private var mediaPath = NavigationPath()
    @State private var sourcesPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    var body: some View {
        SearchTabContainer(
            selection: $selection,
            isExpanded: $isExpanded,
            isShowingSearch: $isShowingSearch,
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
    @Binding var isShowingSearch: Bool
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
        coordinator.contentHost.rootView = isShowingSearch
            ? AnyView(SearchPage {
                isShowingSearch = false
            })
            : pages[selection] ?? AnyView(EmptyView())

        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        let ordered = saved + AppSection.allCases.filter { !saved.contains($0) }
        let excluded = Set(hidden.split(separator: ",").map(String.init))
        let enabled = ordered.filter { $0 == .settings || !excluded.contains($0.rawValue) }
        let showGroup = !allowsHidingTabBar || isExpanded
        let destinationTabs = showGroup ? enabled.compactMap { coordinator.destinations[$0] } : []
        let tabs = destinationTabs + [coordinator.searchTab]

        if controller.tabs.map(\.identifier) != tabs.map(\.identifier) {
            controller.setTabs(tabs, animated: false)
        }
        if controller.selectedTab !== coordinator.searchTab {
            controller.selectedTab = coordinator.searchTab
        }
    }

    final class Coordinator: NSObject, UITabBarControllerDelegate, UIGestureRecognizerDelegate {
        var parent: SearchTabContainer
        weak var controller: UITabBarController?
        let contentHost = UIHostingController(rootView: AnyView(EmptyView()))

        lazy var searchNavigation = UINavigationController(rootViewController: contentHost)

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
            parent.isShowingSearch = false
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
            parent.isExpanded = true
            parent.isShowingSearch = true
            controller.selectedTab = searchTab
            AppLog.info("navigation.search.long_press_opened", category: .navigation)
        }
    }
}

private struct SearchPage: View {
    let close: () -> Void
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Color("VesperSecondaryText"))
                    TextField("搜索当前媒体来源", text: $query)
                        .focused($isSearchFocused)
                        .submitLabel(.search)
                    Button {
                        if isSearchFocused {
                            isSearchFocused = false
                        } else {
                            close()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(isSearchFocused ? "结束输入" : "关闭搜索")
                }
                .padding(.leading, 14)
                .background(Color("VesperSecondaryBackground"), in: RoundedRectangle(cornerRadius: 12))

                ContentUnavailableView(
                    query.isEmpty ? "搜索媒体" : "暂无搜索结果",
                    systemImage: "magnifyingglass",
                    description: Text("搜索当前媒体来源。真实媒体来源尚未接入。")
                )
                Spacer(minLength: 0)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { isSearchFocused = true }
        }
    }
}
