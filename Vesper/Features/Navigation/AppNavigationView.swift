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
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("search.recent") private var recentSearchesData = "[]"
    @AppStorage("miniPlayer.enabled") private var miniPlayerEnabled = true
    @AppStorage("miniPlayer.alwaysVisible") private var miniPlayerAlwaysVisible = true
    @AppStorage("navigation.tabBarCanMinimize") private var tabBarCanMinimize = true
    @State private var selection: NavigationTab
    @StateObject private var library = SourceLibrary()
    @StateObject private var playback = PlaybackSession()
    @State private var mediaPath = NavigationPath()
    @State private var sourcesPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var searchQuery = ""
    @State private var importNotice: String?
    @State private var isShowingImportNotice = false
    @Namespace private var playerTransition

    init() {
        let defaults = UserDefaults.standard
        let preferred = AppSection(rawValue: defaults.string(forKey: "navigation.defaultTab") ?? "media") ?? .media
        let hidden = (defaults.string(forKey: "navigation.hidden") ?? "").split(separator: ",")
        let initial = preferred == .settings || !hidden.contains(Substring(preferred.rawValue)) ? preferred : .settings
        _selection = State(initialValue: .section(initial))
    }

    private var sections: [AppSection] {
        var seen = Set<AppSection>()
        return (order.split(separator: ",").compactMap { AppSection(rawValue: String($0)) } + AppSection.allCases)
            .filter { seen.insert($0).inserted }
    }

    private var visibleSections: [AppSection] {
        sections.filter { $0 == .settings || !hidden.split(separator: ",").contains(Substring($0.rawValue)) }
    }

    private var recentSearches: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(recentSearchesData.utf8))) ?? []
    }

    var body: some View {
        GeometryReader { geometry in
            tabs.environment(\.vesperWindowTopInset, geometry.safeAreaInsets.top)
        }
        .onOpenURL { url in
            Task { await importVideo(url) }
        }
        .alert("视频导入", isPresented: $isShowingImportNotice) {
            Button("好", role: .cancel) { }
        } message: {
            Text(verbatim: importNotice ?? "")
        }
    }

    private var tabs: some View {
        accessoryContent
            .fullScreenCover(isPresented: $playback.isPresented) {
                PlayerScreen(session: playback)
                    .navigationTransition(.zoom(sourceID: "player", in: playerTransition))
            }
    }

    @ViewBuilder
    private var accessoryContent: some View {
        if #available(iOS 26.1, *) {
            tabContent
                .tabViewBottomAccessory(isEnabled: shouldShowMiniPlayer) {
                    MiniPlayerAccessory(session: playback) { playback.isPresented = true }
                        .matchedTransitionSource(id: "player", in: playerTransition)
                }
        } else if shouldShowMiniPlayer {
            tabContent
                .tabViewBottomAccessory {
                    MiniPlayerAccessory(session: playback) { playback.isPresented = true }
                        .matchedTransitionSource(id: "player", in: playerTransition)
                }
        } else {
            tabContent
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        TabView(selection: $selection) {
            ForEach(visibleSections) { section in
                Tab(section.title, systemImage: section.symbol, value: NavigationTab.section(section)) {
                    sectionPage(section)
                }
            }
            Tab("搜索", systemImage: "magnifyingglass", value: NavigationTab.search, role: .search) {
                NavigationStack {
                    Group {
                        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if recentSearches.isEmpty {
                                ContentUnavailableView("无最近搜索", systemImage: "clock.arrow.circlepath")
                            } else {
                                List {
                                    Section("最近搜索") {
                                        ForEach(recentSearches, id: \.self) { query in
                                            Button { searchQuery = query; rememberSearch() } label: {
                                                Label { Text(verbatim: query) } icon: { Image(systemName: "clock.arrow.circlepath") }
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            ContentUnavailableView("暂无搜索结果", systemImage: "magnifyingglass")
                        }
                    }
                    .navigationTitle(searchQuery.isEmpty ? "最近搜索" : "搜索")
                    .toolbarTitleDisplayMode(.inlineLarge)
                    .searchable(text: $searchQuery, prompt: "搜索当前媒体来源")
                    .onSubmit(of: .search) { rememberSearch() }
                }
            }
        }
        .onChange(of: hidden) { _, _ in
            if case let .section(section) = selection, !visibleSections.contains(section) {
                selection = .section(.settings)
            }
        }
        .tabBarMinimizeBehavior(tabBarCanMinimize ? .onScrollDown : .never)
        .tabViewSearchActivation(.searchTabSelection)
        .environmentObject(library)
        .environmentObject(playback)
        .background(VesperTheme.background.ignoresSafeArea())
    }

    private var hasPlayableContent: Bool { playback.currentItem != nil }
    private var shouldShowMiniPlayer: Bool {
        miniPlayerEnabled && (miniPlayerAlwaysVisible || hasPlayableContent)
    }

    private func importVideo(_ url: URL) async {
        do {
            let imported = try await VideoImporter.shared.importVideo(from: url)
            library.selectImportedVideos(name: VesperLocalization.string("本地视频"))
            if visibleSections.contains(.media) {
                mediaPath = NavigationPath()
                selection = .section(.media)
            }
            importNotice = String(localized: "已添加到本地视频：") + imported.lastPathComponent
        } catch {
            importNotice = String(localized: "导入失败：") + error.localizedDescription
        }
        isShowingImportNotice = true
    }

    private func rememberSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let values = Array(([query] + recentSearches.filter { $0 != query }).prefix(20))
        if let data = try? JSONEncoder().encode(values), let value = String(data: data, encoding: .utf8) {
            recentSearchesData = value
        }
    }

    @ViewBuilder
    private func sectionPage(_ section: AppSection) -> some View {
        switch section {
        case .media:
            NavigationStack(path: $mediaPath) { MediaView() }
                .modifier(VesperNavigationHeaderLayer(isRoot: mediaPath.isEmpty))
        case .sources:
            NavigationStack(path: $sourcesPath) { SourcesView() }
                .modifier(VesperNavigationHeaderLayer(isRoot: sourcesPath.isEmpty))
        case .history:
            NavigationStack(path: $historyPath) { HistoryView() }
                .modifier(VesperNavigationHeaderLayer(isRoot: historyPath.isEmpty))
        case .settings:
            NavigationStack(path: $settingsPath) {
                SettingsView()
            }
            .modifier(VesperNavigationHeaderLayer(isRoot: settingsPath.isEmpty))
        }
    }
}

/// TabView supplies the native glass surface and moves this accessory inline
/// when minimizing. Controls share the same app-owned playback session.
private struct MiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @ObservedObject var session: PlaybackSession
    let openPlayer: () -> Void

    private var isCompact: Bool { placement == .inline }

    var body: some View {
        HStack(spacing: isCompact ? 8 : 12) {
            Button(action: openPlayer) {
                HStack(spacing: isCompact ? 8 : 12) {
                    Image(systemName: "play.rectangle")
                        .font(isCompact ? .body : .title2)
                        .frame(width: isCompact ? 24 : 36, height: isCompact ? 24 : 36)
                    Text(verbatim: session.currentItem?.title ?? String(localized: "未在播放"))
                        .font(isCompact ? .footnote.weight(.medium) : .subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开播放器")
            if session.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button(session.isPlaying ? "暂停" : "播放", systemImage: session.isPlaying ? "pause.fill" : "play.fill") {
                    session.togglePlayback()
                }
                .disabled(!session.canControl)
                .labelStyle(.iconOnly)
            }
            if !isCompact {
                Button("下一项", systemImage: "forward.end.fill") { session.next() }.disabled(!session.hasNext)
                    .labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal, isCompact ? 8 : 16)
        .padding(.vertical, isCompact ? 4 : 8)
    }
}
