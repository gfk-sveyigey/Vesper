import SwiftUI
import UIKit
import Combine

private enum NavigationTab: Hashable {
    case section(AppSection)
    case search
}

/// Native tabs own their page hierarchies so scroll tracking, safe areas and
/// the bottom accessory are coordinated by SwiftUI rather than sibling Hosts.
struct AppNavigationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var incomingVideos: IncomingVideoReceiver
    @AppStorage("navigation.order") private var order = "media,sources,history,settings"
    @AppStorage("navigation.hidden") private var hidden = ""
    @AppStorage("search.recent") private var recentSearchesData = "[]"
    @AppStorage("miniPlayer.enabled") private var miniPlayerEnabled = true
    @AppStorage("miniPlayer.alwaysVisible") private var miniPlayerAlwaysVisible = true
    @AppStorage(PlaybackDiagnostics.detachHiddenVideoSurfaceKey) private var detachHiddenVideoSurface = false
    @AppStorage("navigation.tabBarCanMinimize") private var tabBarCanMinimize = true
    @AppStorage(ImageCacheDebugSettings.ignoreLocalCacheKey) private var ignoreLocalImageCache = false
    @State private var selection: NavigationTab
    @StateObject private var library = SourceLibrary()
    @StateObject private var playback = PlaybackSession()
    @StateObject private var appLock = AppLock.shared
    @AppStorage(AppLock.scopeKey) private var protectionScope = "launch"
    @AppStorage(AppLock.enabledKey) private var protectionEnabled = false
    @State private var isInBackground = false
    @State private var mediaPath = NavigationPath()
    @State private var sourcesPath = NavigationPath()
    @State private var sourcesHeaderVisible = true
    @State private var historyPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @State private var searchQuery = ""
    @State private var searchPath = NavigationPath()
    @State private var searchRefreshID = UUID()
    @State private var isShowingClearSearchConfirmation = false
    @State private var videoPickerDismissed = true
    @State private var previewBatch: IncomingVideoBatch?
    @State private var isSavingIncomingBatch = false
    @State private var pendingImportFailures: [String] = []
    @State private var importPresentationHost = VideoImportPresentationProbeController()
    @State private var playerPresentationDismissed = true
    @State private var playAfterPreviewDismiss: IncomingVideo?
    @State private var acknowledgedNonVideoCount = 0
    @State private var importNotice: String?
    @State private var isShowingImportNotice = false

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
        .background {
            // Retain a window-attached rendering surface while PiP is active
            // or the full-screen player is closed by an external presentation.
            if !playback.isPresented, !detachHiddenVideoSurface, let view = playback.videoView {
                PlayerVideoSurface(videoView: view, videoSize: nil, fillsScreen: false)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if appLock.authenticationRequest != nil, !playback.isPresented {
                AppLockScreen()
                    .environmentObject(appLock)
                    .transition(.identity)
                    .transaction { $0.disablesAnimations = true; $0.animation = nil }
                    .zIndex(100)
            }
        }
        .background {
            AppPrivacyBlurHost()
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background {
            VideoImportPresentationProbe(controller: importPresentationHost)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onChange(of: playback.isPresented) { _, presented in
            if presented { playerPresentationDismissed = false }
            PlayerOrientationPolicy.update(presented)
        }
        .onChange(of: library.isPrivacyModeEnabled) { _, enabled in
            guard !enabled else { return }
            stopProtectedSourcePlayback()
            // Discard detail/search routes that may retain a protected source.
            mediaPath = NavigationPath()
            sourcesPath = NavigationPath()
            historyPath = NavigationPath()
            searchPath = NavigationPath()
        }
        .onChange(of: protectionScope) { _, _ in library.refreshProtectionScope() }
        .onChange(of: protectionEnabled) { _, _ in library.refreshProtectionScope() }
        .onChange(of: ignoreLocalImageCache) { _, _ in
            Task {
                await AppCacheStore.shared.invalidateImageWrites()
                library.reload()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            handleScenePhaseChange(phase)
        }
        .task(id: incomingPresentationRequest) { await retryIncomingPresentation() }
        .onChange(of: incomingVideos.batches.map(\.id), initial: true) { _, _ in presentNextIncomingVideo() }
        .onChange(of: incomingVideos.nonVideoCount, initial: true) { _, _ in presentNextIncomingVideo() }
        .onChange(of: isShowingImportNotice) { _, showing in
            if !showing { presentNextIncomingVideo() }
        }
        .onChange(of: incomingVideos.isSelectingVideo) { _, selecting in
            if selecting { videoPickerDismissed = false }
        }
        .sheet(isPresented: $incomingVideos.isSelectingVideo, onDismiss: {
            videoPickerDismissed = true
            presentNextIncomingVideo()
        }) {
            VideoDocumentPicker { files in
                incomingVideos.receivePickedFiles(files)
                incomingVideos.isSelectingVideo = false
            } onCancel: {
                incomingVideos.isSelectingVideo = false
            }
        }
        .sheet(item: $previewBatch, onDismiss: incomingPreviewDismissed) { batch in
            if let file = batch.files.first {
                VideoImportSheet(file: file) {
                    playAfterPreviewDismiss = file
                    previewBatch = nil
                } saved: {
                    library.registerImportedVideos(name: VesperLocalization.string("本地视频"))
                }
                .onAppear {
                    incomingVideos.acknowledgeBatch(batch.id)
                    FileDeliveryLog.write("视频导入面板已显示")
                }
            }
        }
        .alert("视频导入", isPresented: $isShowingImportNotice) {
            Button("好", role: .cancel) { }
        } message: {
            Text(verbatim: importNotice ?? "")
        }
    }

    private func tabIcon(for section: AppSection) -> Image {
        guard section == .media, let source = library.selectedSource else {
            return Image(systemName: section.symbol)
        }
        switch source.kind {
        case .photos: return Image(systemName: "play.rectangle.on.rectangle")
        case .local: return Image(systemName: "folder")
        case .emby:
            let customIcon = source.emby?.iconData.flatMap { UIImage(data: $0) }
            guard let image = customIcon ?? UIImage(named: "EmbyLogo"),
                  image.size.width > 0, image.size.height > 0 else {
                return Image(systemName: "server.rack")
            }
            // Tab bar images need an intrinsic, point-sized canvas rather than
            // the full-resolution source image.
            let size: CGFloat = 25
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            let icon = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
                let bounds = CGRect(x: 0, y: 0, width: size, height: size)
                if customIcon != nil {
                    UIBezierPath(roundedRect: bounds, cornerRadius: size * 0.23).addClip()
                }
                let scale = customIcon == nil
                    ? min(size / image.size.width, size / image.size.height)
                    : max(size / image.size.width, size / image.size.height)
                let width = image.size.width * scale
                let height = image.size.height * scale
                image.withRenderingMode(.alwaysOriginal)
                    .draw(in: CGRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
            }
            // Preserve this flag across SwiftUI's conversion to the native tab item.
            return Image(uiImage: icon.withRenderingMode(.alwaysOriginal)).renderingMode(.original)
        }
    }

    private var tabs: some View {
        accessoryContent
            .fullScreenCover(isPresented: $playback.isPresented, onDismiss: {
                PlayerOrientationPolicy.update(false)
                playerPresentationDismissed = true
                presentNextIncomingVideo()
            }) {
                PlayerScreen(session: playback)
                    .interactiveDismissDisabled(true)
                    .overlay {
                        if appLock.authenticationRequest != nil {
                            AppLockScreen()
                                .environmentObject(appLock)
                                .transition(.identity)
                                .transaction { $0.disablesAnimations = true; $0.animation = nil }
                        }
                    }
            }
    }

    @ViewBuilder
    private var accessoryContent: some View {
        if #available(iOS 26.1, *) {
            tabContent
                .tabViewBottomAccessory(isEnabled: shouldShowMiniPlayer) {
                    MiniPlayerAccessory(session: playback) {
                        if playback.currentItem != nil { playback.isPresented = true }
                    }
                }
        } else if shouldShowMiniPlayer {
            tabContent
                .tabViewBottomAccessory {
                    MiniPlayerAccessory(session: playback) {
                        if playback.currentItem != nil { playback.isPresented = true }
                    }
                }
        } else {
            tabContent
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        TabView(selection: $selection) {
            ForEach(visibleSections) { section in
                Tab(value: NavigationTab.section(section)) {
                    sectionPage(section)
                } label: {
                    Label { Text(section.title) } icon: { tabIcon(for: section) }
                }
            }
            Tab("搜索", systemImage: "magnifyingglass", value: NavigationTab.search, role: .search) {
                NavigationStack(path: $searchPath) {
                    let showsRecentSearches = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    VesperRootScrollView(title: showsRecentSearches ? "最近搜索" : "搜索",
                                         usesSystemList: showsRecentSearches) {
                        if showsRecentSearches {
                            if recentSearches.isEmpty {
                                VesperCenteredEmptyContent(message: "无最近搜索", symbol: "clock.arrow.circlepath")
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(VesperTheme.background)
                            } else {
                                ForEach(recentSearches, id: \.self) { query in
                                    Button {
                                        searchQuery = query
                                        rememberSearch()
                                    } label: {
                                        Label { Text(verbatim: query) } icon: {
                                            Image(systemName: "clock.arrow.circlepath")
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 14)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                                    .listRowSeparator(query == recentSearches.last ? .hidden : .visible)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button("删除", systemImage: "trash", role: .destructive) {
                                            saveRecentSearches(recentSearches.filter { $0 != query })
                                        }
                                    }
                                    .contextMenu {
                                        Button("删除", systemImage: "trash", role: .destructive) {
                                            saveRecentSearches(recentSearches.filter { $0 != query })
                                        }
                                    }
                                    .accessibilityAction(named: Text("删除")) {
                                        saveRecentSearches(recentSearches.filter { $0 != query })
                                    }
                                }
                            }
                        } else {
                            MediaSearchResultsView(query: searchQuery, refreshID: searchRefreshID) { source, item in
                                searchPath.append(SearchMediaRoute(source: source, item: item))
                            }
                        }
                    } actions: {
                        if showsRecentSearches, !recentSearches.isEmpty {
                            Button {
                                isShowingClearSearchConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: Circle())
                            .accessibilityLabel("清空搜索历史")
                        }
                    }
                    .searchable(text: $searchQuery, prompt: "搜索当前媒体来源")
                    .onSubmit(of: .search) { rememberSearch() }
                    .refreshable { searchRefreshID = UUID() }
                    .confirmationDialog("清空全部搜索历史？", isPresented: $isShowingClearSearchConfirmation,
                                        titleVisibility: .visible) {
                        Button("清空搜索历史", role: .destructive) {
                            saveRecentSearches([])
                        }
                        Button("取消", role: .cancel) { }
                    }
                    .navigationDestination(for: SearchMediaRoute.self) { route in
                        MediaDetailView(source: route.source, series: route.item)
                    }
                }
                .modifier(VesperNavigationHeaderLayer(isRoot: searchPath.isEmpty))
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
        .environmentObject(appLock)
        .task {
            if scenePhase == .active { updateAppLock(for: .active) }
        }
        .background(VesperTheme.background.ignoresSafeArea())

    }

    private var hasPlayableContent: Bool { playback.currentItem != nil }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        isInBackground = phase != .active
        updateAppLock(for: phase)
        playback.handleScenePhase(phase)
        if phase == .active, protectionEnabled, protectionScope != "source",
           appLock.authenticationRequest == nil, !appLock.isLocked,
           appLock.lastBackgroundDate == nil {
            appLock.activateIfNeeded()
        }
        if phase == .active { presentNextIncomingVideo() }
    }

    private func updateAppLock(for phase: ScenePhase) {
        if phase == .active, appLock.protectsSources, library.isPrivacyModeEnabled,
           appLock.backgroundGraceExpired {
            stopProtectedSourcePlayback()
            library.setPrivacyMode(false)
        }
        appLock.sceneChanged(phase)
    }

    private func stopProtectedSourcePlayback() {
        if let item = playback.currentItem, library.canUsePrivacyMode,
           library.protectedSourceIDs.contains(item.id.sourceID) {
            playback.stop()
        }
    }

    private var shouldShowMiniPlayer: Bool {
        miniPlayerEnabled && (miniPlayerAlwaysVisible || hasPlayableContent)
    }

    private func presentNextIncomingVideo() {
        startNextAutomaticImport()

        guard scenePhase == .active, videoPickerDismissed, !incomingVideos.isSelectingVideo,
              previewBatch == nil, !isShowingImportNotice, !isSavingIncomingBatch,
              playAfterPreviewDismiss == nil else { return }
        let batch = incomingVideos.batches.first
        let hasNonVideoNotice = incomingVideos.nonVideoCount > acknowledgedNonVideoCount
        guard batch != nil || hasNonVideoNotice || !pendingImportFailures.isEmpty else { return }
        if playback.isPresented {
            // Only a single-video preview needs to close the full-screen UI.
            if batch != nil { playback.isPresented = false }
            return
        }
        guard playerPresentationDismissed, importPresentationHost.canPresent else { return }
        if !pendingImportFailures.isEmpty {
            importNotice = pendingImportFailures.joined(separator: "\n\n")
            pendingImportFailures.removeAll()
            isShowingImportNotice = true
        } else if let batch {
            previewBatch = batch
        } else if hasNonVideoNotice {
            acknowledgedNonVideoCount = incomingVideos.nonVideoCount
            importNotice = VesperLocalization.string("此文件不是视频文件。")
            isShowingImportNotice = true
        }
    }

    private func startNextAutomaticImport() {
        guard !isSavingIncomingBatch,
              let batch = incomingVideos.batches.first(where: \.automaticallySaves) else { return }
        isSavingIncomingBatch = true
        // The task retains every file's access until its copy finishes.
        incomingVideos.acknowledgeBatch(batch.id)
        Task {
            var savedCount = 0
            let unreadableMessage = VesperLocalization.string("无法读取此视频，请先将文件下载到本机后重试。")
            var failures = batch.unreadableFileNames.map { "\($0)\n\(unreadableMessage)" }
            for file in batch.files {
                do {
                    _ = try await VideoImporter.shared.importVideo(file)
                    savedCount += 1
                } catch {
                    failures.append("\(file.name)\n\(error.localizedDescription)")
                    FileDeliveryLog.write("保存失败：\(error.localizedDescription)")
                }
            }
            if savedCount > 0 {
                library.registerImportedVideos(name: VesperLocalization.string("本地视频"))
            }
            FileDeliveryLog.write("批量保存完成，成功=\(savedCount)，失败=\(failures.count)")
            pendingImportFailures.append(contentsOf: failures)
            isSavingIncomingBatch = false
            startNextAutomaticImport()
        }
    }

    private var incomingPresentationRequest: VideoImportPresentationRequest {
        .init(active: scenePhase == .active,
              nextID: incomingVideos.batches.first?.id,
              nonVideoCount: incomingVideos.nonVideoCount,
              previewID: previewBatch?.id,
              selecting: incomingVideos.isSelectingVideo,
              pickerDismissed: videoPickerDismissed,
              noticeVisible: isShowingImportNotice,
              hasSaveFailure: !pendingImportFailures.isEmpty,
              savingBatch: isSavingIncomingBatch,
              playerVisible: playback.isPresented,
              playerDismissed: playerPresentationDismissed,
              awaitingPlay: playAfterPreviewDismiss != nil)
    }

    /// Retry only while there is an actual pending import. This also handles
    /// sheets owned by child pages, whose dismissal the root cannot observe.
    private func retryIncomingPresentation() async {
        startNextAutomaticImport()
        guard scenePhase == .active else { return }
        if let reserved = previewBatch,
           incomingVideos.batches.contains(where: { $0.id == reserved.id }) {
            // onAppear normally acknowledges immediately. If SwiftUI rejected
            // the request because another presenter won the race, release the
            // reservation and retry without removing the queued file.
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard scenePhase == .active, previewBatch?.id == reserved.id,
                  incomingVideos.batches.contains(where: { $0.id == reserved.id }) else { return }
            FileDeliveryLog.write("导入面板尚未显示，保留文件并等待重新展示")
            previewBatch = nil
            return
        }
        // Explicit new-file/foreground events may dismiss the current player.
        // A retry alone must not immediately close Direct Play just chosen
        // from the previous sheet merely because more files remain queued.
        guard previewBatch == nil, !isShowingImportNotice, !isSavingIncomingBatch,
              playAfterPreviewDismiss == nil, !incomingVideos.isSelectingVideo,
              videoPickerDismissed else { return }
        guard !playback.isPresented else { return }
        while !Task.isCancelled,
              !incomingVideos.batches.isEmpty || !pendingImportFailures.isEmpty
                || incomingVideos.nonVideoCount > acknowledgedNonVideoCount {
            presentNextIncomingVideo()
            if previewBatch != nil || isShowingImportNotice || isSavingIncomingBatch { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
    }

    private func incomingPreviewDismissed() {
        if let file = playAfterPreviewDismiss {
            playAfterPreviewDismiss = nil
            playback.playExternal(file)
        } else {
            presentNextIncomingVideo()
        }
    }

    private func rememberSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let values = Array(([query] + recentSearches.filter { $0 != query }).prefix(20))
        saveRecentSearches(values)
    }

    private func saveRecentSearches(_ values: [String]) {
        if let data = try? JSONEncoder().encode(values), let value = String(data: data, encoding: .utf8) {
            recentSearchesData = value
        }
    }

    @ViewBuilder
    private func sectionPage(_ section: AppSection) -> some View {
        switch section {
        case .media:
            NavigationStack(path: $mediaPath) {
                MediaView(path: $mediaPath)
            }
                .modifier(VesperNavigationHeaderLayer(isRoot: mediaPath.isEmpty))
        case .sources:
            NavigationStack(path: $sourcesPath) {
                SourcesView { sourcesHeaderVisible = $0 }
            }
                .modifier(VesperNavigationHeaderLayer(isRoot: sourcesPath.isEmpty && sourcesHeaderVisible))
        case .history:
            NavigationStack(path: $historyPath) { HistoryView(path: $historyPath) }
                .modifier(VesperNavigationHeaderLayer(isRoot: historyPath.isEmpty))
        case .settings:
            NavigationStack(path: $settingsPath) {
                SettingsView(path: $settingsPath)
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
                    Text(verbatim: session.currentItem?.title ?? VesperLocalization.string("未在播放"))
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
                    if !session.isPlaying && !session.isPictureInPictureActive { session.isPresented = true }
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


// A probe in the same window as the tab root avoids presenting while another
// page's sheet/alert or a UIKit transition already occupies that presenter.
private struct VideoImportPresentationRequest: Hashable {
    let active: Bool
    let nextID: UUID?
    let nonVideoCount: Int
    let previewID: UUID?
    let selecting: Bool
    let pickerDismissed: Bool
    let noticeVisible: Bool
    let hasSaveFailure: Bool
    let savingBatch: Bool
    let playerVisible: Bool
    let playerDismissed: Bool
    let awaitingPlay: Bool
}

private struct VideoImportPresentationProbe: UIViewControllerRepresentable {
    let controller: VideoImportPresentationProbeController
    func makeUIViewController(context: Context) -> VideoImportPresentationProbeController { controller }
    func updateUIViewController(_ uiViewController: VideoImportPresentationProbeController, context: Context) {}
}

private final class VideoImportPresentationProbeController: UIViewController {
    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    var canPresent: Bool {
        guard let window = viewIfLoaded?.window,
              window.windowScene?.activationState == .foregroundActive,
              let root = window.rootViewController else { return false }
        guard !root.isBeingPresented, !root.isBeingDismissed,
              root.transitionCoordinator == nil else { return false }
        // SwiftUI creates many internal child controllers. Only a real modal
        // attached to the root should defer this sheet presentation.
        return root.presentedViewController == nil
    }
}


/// Keep search details in their originating stack so returning restores the search page.
private struct SearchMediaRoute: Hashable {
    let source: MediaSource
    let item: MediaItem

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source.id == rhs.source.id && lhs.item == rhs.item
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(source.id)
        hasher.combine(item)
    }
}

/// Each request captures its source configuration as well as its query, so switching
/// accounts or server routes cannot publish results from an obsolete request.
private struct MediaSearchRequest: Equatable {
    let source: MediaSource?
    let query: String
    let retry: UUID
    let refreshID: UUID
}

private struct MediaSearchResultsView: View {
    @ObservedObject private var layout = MediaLayoutSettings.shared
    let query: String
    let refreshID: UUID
    let openDetail: (MediaSource, MediaItem) -> Void
    @Environment(\.vesperEmptyContentHeight) private var emptyHeight
    @Environment(\.vesperRootHeaderHeight) private var rootHeaderHeight
    @EnvironmentObject private var library: SourceLibrary
    @EnvironmentObject private var playback: PlaybackSession
    @State private var items: [MediaItem] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var retry = UUID()
    @State private var generation = UUID()
    @State private var loadedSource: MediaSource?
    @State private var nextIndex = 0
    @State private var hasMore = false
    @State private var loadingMore = false
    @State private var moreError: String?
    @State private var moreTask: Task<Void, Never>?

    private var request: MediaSearchRequest {
        MediaSearchRequest(source: library.selectedSource,
                           query: query.trimmingCharacters(in: .whitespacesAndNewlines), retry: retry, refreshID: refreshID)
    }

    var body: some View {
        Group {
            if library.selectedSource == nil {
                ContentUnavailableView("未配置来源", systemImage: "server.rack",
                                       description: Text("请先在来源标签页选择一个媒体来源。"))
                    .frame(minHeight: emptyHeight)
            } else if loading {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityHidden(true)
                    Text("正在搜索")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color(uiColor: .label))
                }
                .frame(maxWidth: .infinity, minHeight: emptyHeight)
                .offset(y: -rootHeaderHeight / 2)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("搜索失败", systemImage: "exclamationmark.magnifyingglass")
                } description: {
                    Text(verbatim: errorMessage)
                } actions: {
                    Button("重试") { retry = UUID() }
                }
                .frame(minHeight: emptyHeight)
            } else if let source = loadedSource {
                resultList(source)
            }
        }
        .task(id: request) { await search(request) }
        .onDisappear { moreTask?.cancel() }
    }

    private func resultList(_ source: MediaSource) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text(verbatim: source.kind == .local ? VesperLocalization.string("本地视频")
                 : source.kind == .photos ? VesperLocalization.string("相册视频") : source.name)
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.bottom, 12)
            ForEach(items) { item in
                Button {
                    open(item, source: source)
                } label: {
                    MediaLibraryListRow(source: source, item: item, playback: playback)
                }
                .buttonStyle(.plain)
                .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback,
                                             showsEmbyFacts: source.kind == .emby,
                                             openEmbyDetails: { open(item, source: source) }) { EmptyView() })
                if item.id != items.last?.id {
                    Divider().padding(.leading, MediaLibraryListRow(source: source, item: item).dividerInset)
                }
            }
            if items.isEmpty {
                VesperCenteredEmptyContent(message: "暂无搜索结果", symbol: "magnifyingglass")
            }
            if hasMore {
                VStack(spacing: 8) {
                    if let moreError { Text(verbatim: moreError).font(.footnote).foregroundStyle(.secondary) }
                    Button {
                        moreTask?.cancel()
                        moreTask = Task { await loadMore(source: source, token: generation) }
                    } label: {
                        if loadingMore { ProgressView() }
                        else { Text("加载更多") }
                    }
                    .disabled(loadingMore)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .padding(.top, CGFloat(layout[.browserListTop]))
        .padding(.leading, CGFloat(layout[.browserListLeading]))
        .padding(.bottom, CGFloat(layout[.browserListBottom]))
        .padding(.trailing, CGFloat(layout[.browserListTrailing]))
    }

    private func open(_ item: MediaItem, source: MediaSource) {
        if source.kind == .emby {
            openDetail(source, item)
        } else { playback.play(item, in: source, queue: items) }
    }

    @MainActor private func search(_ snapshot: MediaSearchRequest) async {
        let token = UUID()
        generation = token
        moreTask?.cancel()
        loadingMore = false
        items = []
        errorMessage = nil
        moreError = nil
        hasMore = false
        nextIndex = 0
        loadedSource = nil
        loading = snapshot.source != nil
        guard let source = snapshot.source, !snapshot.query.isEmpty else { loading = false; return }
        do {
            try await Task.sleep(for: .milliseconds(350))
            let found: [MediaItem]
            var page: EmbySearchPage?
            switch source.kind {
            case .emby:
                let result = try await library.catalog.search(for: source, query: snapshot.query)
                page = result
                found = result.items
            case .local:
                let root = try source.localFolderURL()
                let files = try await LocalFileStore.shared.matchingFiles(root: root, query: snapshot.query)
                found = files.filter { VideoImporter.isVideoType(URL(fileURLWithPath: $0.name)) }.map {
                    MediaItem(id: MediaID(sourceID: source.id, localID: $0.path),
                              title: ($0.name as NSString).deletingPathExtension, resource: nil,
                              subtitle: ($0.path as NSString).deletingLastPathComponent)
                }
            case .photos:
                found = try await DeviceSourceAdapter().media(in: source)
                    .filter { $0.title.localizedStandardContains(snapshot.query) }
            }
            try Task.checkCancellation()
            guard generation == token, request == snapshot else { return }
            var seen = Set<MediaID>()
            items = found.filter { seen.insert($0.id).inserted }
            loadedSource = source
            nextIndex = page?.nextIndex ?? 0
            hasMore = page?.hasMore ?? false
            loading = false
        } catch {
            guard !Task.isCancelled, generation == token, request == snapshot else { return }
            errorMessage = error is SourceFailure
                ? VesperLocalization.string("无法读取当前来源，请检查访问权限后重试。") : error.localizedDescription
            loading = false
        }
    }

    @MainActor private func loadMore(source: MediaSource, token: UUID) async {
        guard !loadingMore, hasMore, source == library.selectedSource else { return }
        let snapshot = request
        loadingMore = true
        moreError = nil
        do {
            let result = try await library.catalog.search(for: source, query: snapshot.query, startIndex: nextIndex)
            try Task.checkCancellation()
            guard generation == token, request == snapshot else { return }
            var seen = Set(items.map(\.id))
            items += result.items.filter { seen.insert($0.id).inserted }
            nextIndex = result.nextIndex
            hasMore = result.hasMore
        } catch {
            guard !Task.isCancelled, generation == token, request == snapshot else { return }
            moreError = error.localizedDescription
        }
        if generation == token { loadingMore = false }
    }
}
