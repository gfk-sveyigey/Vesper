import SwiftUI

struct AppNavigationView: View {
    @State private var isTabBarVisible = false
    @State private var selection: AppSection = .media
    @State private var mediaPath = NavigationPath()
    @State private var sourcesPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var settingsPath = NavigationPath()

    var body: some View {
        TabView(selection: $selection) {
            Tab(AppSection.media.title, systemImage: AppSection.media.symbol, value: AppSection.media) {
                NavigationStack(path: $mediaPath) {
                    MediaView(openSources: { selection = .sources })
                }
                .modifier(TabBarPresentation(isVisible: $isTabBarVisible))
            }
            Tab(AppSection.sources.title, systemImage: AppSection.sources.symbol, value: AppSection.sources) {
                NavigationStack(path: $sourcesPath) { SourcesView() }
                    .modifier(TabBarPresentation(isVisible: $isTabBarVisible))
            }
            Tab(AppSection.history.title, systemImage: AppSection.history.symbol, value: AppSection.history) {
                NavigationStack(path: $historyPath) { HistoryView() }
                    .modifier(TabBarPresentation(isVisible: $isTabBarVisible))
            }
            Tab(AppSection.settings.title, systemImage: AppSection.settings.symbol, value: AppSection.settings) {
                NavigationStack(path: $settingsPath) { SettingsView() }
                    .modifier(TabBarPresentation(isVisible: $isTabBarVisible))
            }
        }
        .background(Color("VesperBackground"))
        .onChange(of: selection) { _, section in
            AppLog.info("navigation.selected.\(section.rawValue)", category: .navigation)
        }
    }
}

/// The system owns the tab bar. This modifier only controls its visibility.
private struct TabBarPresentation: ViewModifier {
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if isVisible {
                    Button {
                        isVisible = false
                        AppLog.debug("navigation.tabs.dismissed", category: .navigation)
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("收起标签栏")
                    .accessibilityHint("收起后可继续操作当前页面")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isVisible.toggle()
                        AppLog.debug("navigation.tabs.toggled", category: .navigation)
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .accessibilityLabel("多任务")
                    .accessibilityValue(isVisible ? "标签栏已显示" : "标签栏已隐藏")
                    .accessibilityHint("显示或隐藏媒体、来源、记录和设置标签")
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                }
            }
            .toolbar(isVisible ? .visible : .hidden, for: .tabBar)
            .toolbarBackground(.hidden, for: .tabBar)
            .accessibilityAction(.escape) { isVisible = false }
    }
}
