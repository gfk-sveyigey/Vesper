import SwiftUI
import UIKit

struct AppNavigationView: View {
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
                NativeTabBar(selection: $selection, isExpanded: $isExpanded)
                    .frame(height: 49)
            }
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

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITabBar {
        let bar = UITabBar()
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.tintColor = UIColor(named: "VesperAccent")
        bar.delegate = context.coordinator
        return bar
    }

    func updateUIView(_ bar: UITabBar, context: Context) {
        context.coordinator.parent = self
        let coordinator = context.coordinator
        let items = isExpanded ? coordinator.sections + [coordinator.action] : [coordinator.action]
        if bar.items?.map(\.tag) != items.map(\.tag) {
            bar.setItems(items, animated: false)
        }
        coordinator.action.accessibilityValue = isExpanded ? "已展开" : "已收起"
        bar.selectedItem = isExpanded
            ? coordinator.sections[AppSection.allCases.firstIndex(of: selection) ?? 0]
            : nil
    }

    final class Coordinator: NSObject, UITabBarDelegate {
        var parent: NativeTabBar
        let sections: [UITabBarItem] = AppSection.allCases.enumerated().map { index, section in
            UITabBarItem(title: section.title, image: UIImage(systemName: section.symbol), tag: index)
        }
        let action: UITabBarItem = {
            let item = UITabBarItem(tabBarSystemItem: .search, tag: 100)
            item.accessibilityLabel = "多功能"
            item.accessibilityHint = "显示或隐藏媒体、来源、记录和设置标签"
            return item
        }()

        init(parent: NativeTabBar) { self.parent = parent }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            if item.tag == action.tag {
                parent.isExpanded.toggle()
            } else if AppSection.allCases.indices.contains(item.tag) {
                parent.selection = AppSection.allCases[item.tag]
            }
            // The action never becomes the selected destination.
            tabBar.selectedItem = parent.isExpanded
                ? sections[AppSection.allCases.firstIndex(of: parent.selection) ?? 0]
                : nil
        }
    }
}
