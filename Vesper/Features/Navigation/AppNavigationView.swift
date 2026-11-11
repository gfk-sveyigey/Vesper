import SwiftUI

struct AppNavigationView: View {
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
                .toolbarBackground(.hidden, for: .tabBar)
            }
            Tab(AppSection.sources.title, systemImage: AppSection.sources.symbol, value: AppSection.sources) {
                NavigationStack(path: $sourcesPath) { SourcesView() }
                    .toolbarBackground(.hidden, for: .tabBar)
            }
            Tab(AppSection.history.title, systemImage: AppSection.history.symbol, value: AppSection.history) {
                NavigationStack(path: $historyPath) { HistoryView() }
                    .toolbarBackground(.hidden, for: .tabBar)
            }
            Tab(AppSection.settings.title, systemImage: AppSection.settings.symbol, value: AppSection.settings) {
                NavigationStack(path: $settingsPath) { SettingsView() }
                    .toolbarBackground(.hidden, for: .tabBar)
            }
        }
        .background(Color("VesperBackground"))
        .onChange(of: selection) { _, section in
            AppLog.info("navigation.selected.\(section.rawValue)", category: .navigation)
        }
    }
}
