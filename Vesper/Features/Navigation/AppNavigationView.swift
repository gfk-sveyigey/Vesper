import SwiftUI
import UIKit

struct AppNavigationView: View {
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @State private var showsSearch = false
    @State private var isExpanded = false
    @State private var selection: AppSection = .media
    @State private var mediaPath = NavigationPath()
    @State private var sourcesPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    var body: some View {
        selectedContent
            .overlay {
                if isExpanded {
                    Button { isExpanded = false } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("收起区域标签")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                NativeTabBar(selection: $selection, isExpanded: $isExpanded, visibleSections: visibleSections, openSearch: {
                    isExpanded = false
                    showsSearch = true
                })
                    .frame(height: 49)
            }
            .sheet(isPresented: $showsSearch) { SearchView() }
            .background(Color("VesperBackground"))
            .accessibilityAction(.escape) { isExpanded = false }
            .onChange(of: selection) { _, section in
                AppLog.info("navigation.selected.\(section.rawValue)", category: .navigation)
            }
            .onChange(of: isExpanded) { _, expanded in
                AppLog.debug("navigation.tabs.toggled", category: .navigation,
                             detail: "expanded=\(expanded)")
            }
    }

    private var visibleSections: [AppSection] {
        let ordered = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        let complete = ordered + AppSection.allCases.filter { !ordered.contains($0) }
        let excluded = Set(hidden.split(separator: ",").map(String.init))
        return complete.filter { !excluded.contains($0.rawValue) }
    }

    @ViewBuilder private var selectedContent: some View {
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
}

/// UIKit owns every item, its rendering, hit testing and accessibility.
/// The persistent action item is not a destination, so TabView selection is not used.
private struct NativeTabBar: UIViewRepresentable {
    @Binding var selection: AppSection
    @Binding var isExpanded: Bool

    let visibleSections: [AppSection]
    let openSearch: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITabBar {
        let bar = UITabBar()
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.tintColor = UIColor(named: "VesperAccent")
        bar.delegate = context.coordinator
        bar.itemPositioning = .fill
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPress(_:)))
        longPress.delegate = context.coordinator
        bar.addGestureRecognizer(longPress)
        context.coordinator.action.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "打开搜索", target: context.coordinator, selector: #selector(Coordinator.searchAccessibility))
        ]
        return bar
    }

    func updateUIView(_ bar: UITabBar, context: Context) {
        context.coordinator.parent = self
        let coordinator = context.coordinator
        let items = isExpanded ? visibleSections.map { coordinator.item(for: $0) } + [coordinator.action] : [coordinator.action]
        if bar.items?.map(\.tag) != items.map(\.tag) {
            bar.setItems(items, animated: false)
        }
        coordinator.action.accessibilityValue = isExpanded ? "已展开" : "已收起"
        bar.selectedItem = isExpanded
            ? coordinator.sections.first { $0.tag == AppSection.allCases.firstIndex(of: selection) && items.contains($0) }
            : nil
    }

    final class Coordinator: NSObject, UITabBarDelegate, UIGestureRecognizerDelegate {
        var parent: NativeTabBar
        let sections: [UITabBarItem] = AppSection.allCases.enumerated().map { index, section in
            UITabBarItem(title: section.title, image: UIImage(systemName: section.symbol), tag: index)
        }
        let action: UITabBarItem = {
            let item = UITabBarItem(title: "多功能", image: UIImage(systemName: "square.grid.2x2"), tag: 100)
            item.accessibilityLabel = "多功能"
            item.accessibilityHint = "轻点显示或隐藏标签，长按打开搜索"
            return item
        }()

        init(parent: NativeTabBar) { self.parent = parent }

        func item(for section: AppSection) -> UITabBarItem {
            sections[AppSection.allCases.firstIndex(of: section)!]
        }

        @objc func searchAccessibility() -> Bool {
            parent.openSearch()
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let bar = gestureRecognizer.view as? UITabBar,
                  let items = bar.items, !items.isEmpty else { return false }
            // .fill gives each native item an equal-width slot; only the final action slot handles long press.
            return gestureRecognizer.location(in: bar).x >= bar.bounds.width * CGFloat(items.count - 1) / CGFloat(items.count)
        }

        @objc func longPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            parent.openSearch()
        }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            if item.tag == action.tag {
                parent.isExpanded.toggle()
            } else if AppSection.allCases.indices.contains(item.tag) {
                parent.selection = AppSection.allCases[item.tag]
            }
            // The action never becomes the selected destination.
            tabBar.selectedItem = parent.isExpanded
                ? tabBar.items?.first { $0.tag == AppSection.allCases.firstIndex(of: parent.selection) }
                : nil
        }
    }
}
