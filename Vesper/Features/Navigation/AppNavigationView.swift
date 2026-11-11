import SwiftUI
import UIKit

private enum NavigationTab: Hashable {
    case section(AppSection)
    case multifunction
}

struct AppNavigationView: View {
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("navigation.allowsHidingTabBar") private var allowsHidingTabBar = true
    @AppStorage("navigation.gestureOrder") private var gestures = "tap,longPress"
    @AppStorage("navigation.actionOrder") private var actions = "tabs,search"
    @State private var selection: AppSection = .media
    @State private var isExpanded = false
    @State private var isInitializingSelection = true
    @State private var isSearchPresented = false
    @State private var hosts = SectionHosts()

    private var enabledSections: [AppSection] {
        let saved = order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }
        let ordered = saved + AppSection.allCases.filter { !saved.contains($0) }
        let excluded = Set(hidden.split(separator: ",").map(String.init))
        return ordered.filter {
            $0 == .settings || (isInitializingSelection && $0 == selection)
                || !excluded.contains($0.rawValue)
        }
    }

    private var showPrimaryTabs: Bool { isInitializingSelection || !allowsHidingTabBar || isExpanded }

    private var tabSelection: Binding<NavigationTab> {
        Binding(
            get: {
                // A hidden tab cannot display content. The multifunction tab
                // carries the same section host while its entry is hidden.
                showPrimaryTabs && !isSearchPresented && enabledSections.contains(selection)
                    ? .section(selection) : .multifunction
            },
            set: { tab in
                // Search-role selection alone must not activate search. Its
                // tap/long-press actions are handled separately below.
                guard case let .section(section) = tab else { return }
                isSearchPresented = false
                selection = section
                AppLog.info("navigation.selected.\(section.rawValue)", category: .navigation)
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            primaryTabs

            Tab("多功能", systemImage: "square.grid.2x2", value: NavigationTab.multifunction, role: .search) {
                if isSearchPresented {
                    SearchPage(isPresented: $isSearchPresented)
                } else {
                    SectionHostSlot(
                        host: hosts.controller(for: selection, openSources: openSources),
                        active: !showPrimaryTabs || !enabledSections.contains(selection)
                    )
                }
            }
        }
        .tint(Color("VesperAccent"))
        .toolbarBackground(.hidden, for: .tabBar)
        .background(MultifunctionGestures(
            tap: { performGesture("tap") },
            longPress: { performGesture("longPress") }
        ))
        .transaction { $0.animation = nil }
    }

    private var primaryTabs: some TabContent<NavigationTab> {
        TabSection("主要功能") {
            ForEach(enabledSections) { section in
                Tab(section.title, systemImage: section.symbol, value: NavigationTab.section(section)) {
                    SectionHostSlot(
                        host: hosts.controller(for: section, openSources: openSources),
                        active: showPrimaryTabs && !isSearchPresented && selection == section,
                        onVisible: { finishInitialSelection(for: section) }
                    )
                }
            }
        }
        .hidden(!showPrimaryTabs)
    }

    private func finishInitialSelection(for section: AppSection) {
        guard isInitializingSelection, selection == section else { return }
        isInitializingSelection = false
        AppLog.info("navigation.initialSelection.ready", category: .navigation)
    }

    private func openSources() {
        isInitializingSelection = false
        isSearchPresented = false
        selection = .sources
    }

    private func performGesture(_ gesture: String) {
        let gestureValues = gestures.split(separator: ",").map(String.init)
        let actionValues = actions.split(separator: ",").map(String.init)
        guard let index = gestureValues.firstIndex(of: gesture), actionValues.indices.contains(index) else { return }
        // An explicit action takes precedence over startup auto-collapse.
        isInitializingSelection = false
        if actionValues[index] == "tabs" {
            if allowsHidingTabBar { isExpanded.toggle() }
        } else {
            if allowsHidingTabBar { isExpanded = true }
            isSearchPresented = true
        }
    }
}

/// A section has one hosting controller and one locally owned NavigationStack.
/// The current section stays visible in the multifunction slot when the
/// primary group is hidden. Its hosting controller and navigation stack persist.
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

private struct SectionHostSlot: UIViewControllerRepresentable {
    let host: UIViewController
    let active: Bool
    var onVisible: () -> Void = {}

    func makeUIViewController(context: Context) -> SlotController { SlotController() }

    func updateUIViewController(_ container: SlotController, context: Context) {
        container.onVisible = active ? onVisible : {}
        container.reportVisibilityIfReady()
        guard active, host.parent !== container else { return }
        for previous in container.children {
            previous.willMove(toParent: nil)
            previous.view.removeFromSuperview()
            previous.removeFromParent()
        }
        if host.parent != nil {
            host.willMove(toParent: nil)
            host.viewIfLoaded?.removeFromSuperview()
            host.removeFromParent()
        }
        container.addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor)
        ])
        host.didMove(toParent: container)
    }

    final class SlotController: UIViewController {
        var onVisible: () -> Void = {}
        private var appeared = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared = true
            reportVisibilityIfReady()
        }

        override func viewWillDisappear(_ animated: Bool) {
            appeared = false
            super.viewWillDisappear(animated)
        }

        func reportVisibilityIfReady() {
            guard appeared else { return }
            // Complete startup after UIKit's appearance callback, not during
            // a representable update. No fixed delay or search-entry staging.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.appeared else { return }
                self.onVisible()
            }
        }
    }
}

/// Only bridges gestures on the system tab bar; does not replace its delegate,
/// tabs, selection, or access private UIKit view types.
private struct MultifunctionGestures: UIViewControllerRepresentable {
    let tap: () -> Void
    let longPress: () -> Void

    func makeUIViewController(context: Context) -> GestureController {
        GestureController(tap: tap, longPress: longPress)
    }

    func updateUIViewController(_ controller: GestureController, context: Context) {
        controller.tapAction = tap
        controller.longPressAction = longPress
        controller.installWhenReady()
    }

    static func dismantleUIViewController(_ controller: GestureController, coordinator: ()) {
        controller.uninstall()
    }

    final class GestureController: UIViewController, UIGestureRecognizerDelegate {
        var tapAction: () -> Void
        var longPressAction: () -> Void
        private weak var installedBar: UITabBar?
        private lazy var tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(tapped))
        private lazy var pressRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))

        init(tap: @escaping () -> Void, longPress: @escaping () -> Void) {
            tapAction = tap
            longPressAction = longPress
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installWhenReady()
        }

        func installWhenReady() {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            guard let controller = findTabController(in: root) else { return }
            for tab in controller.tabs {
                if let search = tab as? UISearchTab {
                    search.automaticallyActivatesSearch = false
                    search.image = UIImage(systemName: "square.grid.2x2")
                }
            }
            let bar = controller.tabBar
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
            guard let bar = installedBar else { return false }
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
