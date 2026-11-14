import SwiftUI

private enum NavigationTab: Hashable {
    case section(AppSection)
    case search
}

/// Native tabs own their page hierarchies so scroll tracking, safe areas and
/// the bottom accessory are coordinated by SwiftUI rather than sibling Hosts.
struct AppNavigationView: View {
    @AppStorage("navigation.icons") private var icons = "{}"
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @State private var selection = NavigationTab.section(.media)
    @StateObject private var library = SourceLibrary()
    @State private var mediaPath = NavigationPath()
    @State private var sourcesPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var searchQuery = ""
    @State private var isPlayerPresented = false
    @Namespace private var playerTransition

    private var sections: [AppSection] {
        var seen = Set<AppSection>()
        return (order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) } + AppSection.allCases)
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        // Measure outside each NavigationStack, as in build 166, so the value
        // describes the status safe area rather than the navigation title bar.
        GeometryReader { geometry in
            tabs.environment(\.vesperWindowTopInset, geometry.safeAreaInsets.top)
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            ForEach(sections) { section in
                Tab(section.title, systemImage: section.symbol, value: NavigationTab.section(section)) {
                    sectionPage(section)
                }
            }
            Tab("搜索", systemImage: "magnifyingglass", value: NavigationTab.search, role: .search) {
                NavigationStack {
                    ContentUnavailableView(
                        searchQuery.isEmpty ? "搜索媒体" : "暂无搜索结果",
                        systemImage: "magnifyingglass"
                    )
                    .navigationTitle("搜索")
                    .toolbarTitleDisplayMode(.inlineLarge)
                    .searchable(text: $searchQuery, prompt: "搜索当前媒体来源")
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewSearchActivation(.searchTabSelection)
        .tabViewBottomAccessory {
            MiniPlayerAccessory { isPlayerPresented = true }
                .matchedTransitionSource(id: "player", in: playerTransition)
        }
        .environmentObject(library)
        .background(VesperTheme.background.ignoresSafeArea())
        .fullScreenCover(isPresented: $isPlayerPresented) {
            NavigationStack {
                ContentUnavailableView("未在播放", systemImage: "play.rectangle",
                    description: Text("选择媒体后即可开始播放。"))
                    .navigationTitle("播放器")
                    .toolbarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭", systemImage: "chevron.down") { isPlayerPresented = false }
                        }
                    }
            }
            .navigationTransition(.zoom(sourceID: "player", in: playerTransition))
        }
    }

    @ViewBuilder
    private func sectionPage(_ section: AppSection) -> some View {
        switch section {
        case .media:
            NavigationStack(path: $mediaPath) { MediaView() }
        case .sources:
            NavigationStack(path: $sourcesPath) { SourcesView() }
        case .history:
            NavigationStack(path: $historyPath) { HistoryView() }
        case .settings:
            NavigationStack(path: $settingsPath) {
                SettingsView(openSection: { selection = .section($0) })
            }
        }
    }
}

/// TabView supplies the native glass surface and moves this accessory inline
/// when minimizing. Transport stays disabled until a real session exists.
private struct MiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let openPlayer: () -> Void

    private var isCompact: Bool { placement == .inline }

    var body: some View {
        HStack(spacing: isCompact ? 8 : 12) {
            Button(action: openPlayer) {
                HStack(spacing: isCompact ? 8 : 12) {
                    Image(systemName: "play.rectangle")
                        .font(isCompact ? .body : .title2)
                        .frame(width: isCompact ? 24 : 36, height: isCompact ? 24 : 36)
                    Text("未在播放")
                        .font(isCompact ? .footnote.weight(.medium) : .subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开播放器")
            Button("播放", systemImage: "play.fill") {}.disabled(true)
                .labelStyle(.iconOnly)
            if !isCompact {
                Button("下一项", systemImage: "forward.end.fill") {}.disabled(true)
                    .labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal, isCompact ? 8 : 16)
        .padding(.vertical, isCompact ? 4 : 8)
    }
}
