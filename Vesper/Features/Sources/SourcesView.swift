import SwiftUI
import Photos
import UIKit

private enum SourcesAlert: Hashable, Identifiable {
    case addSource
    case localNetwork
    case refreshRoutes(String)
    var id: Self { self }
}

struct SourcesView: View {
    private struct EditorRequest: Identifiable {
        let source: MediaSource
        let entry: EmbySourceEditor.Entry
        var id: UUID { source.id }
    }

    var headerVisibilityChanged: (Bool) -> Void = { _ in }
    @EnvironmentObject private var library: SourceLibrary
    @State private var activeAlert: SourcesAlert?
    @State private var isShowingEmbyEditor = false
    @State private var editingEmby: EditorRequest?
    @State private var refreshingRoutes: Set<UUID> = []

    var body: some View {
        VesperRootScrollView(title: "来源") {
            if library.sources.isEmpty {
                VesperCenteredEmptyContent(message: "未配置来源", symbol: AppSection.sources.symbol)
            } else {
                VStack(spacing: 0) {
                    ForEach(library.orderedSources) { source in
                        SourceListRow(source: source, isSelected: source.id == library.selectedID,
                                      latency: library.routeLatencies[source.id]) {
                            selectSource(source)
                        }
                        .contextMenu {
                            if let configuration = source.emby {
                                Button("编辑来源", systemImage: "pencil") {
                                    editingEmby = EditorRequest(source: source, entry: .general)
                                }
                                Button("修改图标", systemImage: "photo") {
                                    editingEmby = EditorRequest(source: source, entry: .icon)
                                }
                                Button("编辑线路", systemImage: "point.3.connected.trianglepath.dotted") {
                                    editingEmby = EditorRequest(source: source, entry: .routes)
                                }
                                Button("刷新线路", systemImage: "arrow.clockwise") { refreshRoutes(source.id) }
                                    .disabled(refreshingRoutes.contains(source.id))
                                Menu("切换线路", systemImage: "arrow.left.arrow.right") {
                                    let primary = configuration.primaryRoute
                                    ForEach([primary] + configuration.backupRoutes, id: \.self) { address in
                                        let key = EmbyRouteOptions.key(address)
                                        let name = address == primary ? VesperLocalization.string("主线路") :
                                            configuration.alternateRouteNames?[key] ?? URLComponents(string: address)?.host ?? address
                                        Button {
                                            library.switchEmbyRoute(source.id, address: address)
                                        } label: {
                                            if key == EmbyRouteOptions.key(configuration.serverAddress) {
                                                Label(name, systemImage: "checkmark")
                                            } else {
                                                Text(verbatim: name)
                                            }
                                        }
                                    }
                                }
                            }
                            Button("移除来源", systemImage: "trash", role: .destructive) { library.remove(source.id) }
                        }
                        .accessibilityAction(named: Text("移除来源")) { library.remove(source.id) }
                    }
                    if library.storageFailed { Text("来源设置保存失败").foregroundStyle(.red) }
                }
            }
        } actions: {
            addMenu
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .addSource:
                Alert(title: Text("无法添加来源"), message: Text("请检查相册访问权限或本地视频文件。"),
                      dismissButton: .cancel(Text("好")))
            case .refreshRoutes(let message):
                Alert(title: Text("无法刷新线路"), message: Text(verbatim: message),
                      dismissButton: .cancel(Text("好")))
            case .localNetwork:
                Alert(title: Text("无法访问本地网络"),
                      message: Text("请在系统设置中允许 Vesper 访问本地网络，然后重新选择 Emby 来源。"),
                      primaryButton: .default(Text("前往设置")) {
                          guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                          UIApplication.shared.open(url)
                      },
                      secondaryButton: .cancel(Text("取消")))
            }
        }
        .onChange(of: isShowingEmbyEditor || editingEmby != nil, initial: true) { _, presentsEditor in
            headerVisibilityChanged(!presentsEditor)
        }
        .sheet(isPresented: $isShowingEmbyEditor) { EmbySourceEditor(source: nil) }
        .sheet(item: $editingEmby) { request in
            EmbySourceEditor(source: request.source, entry: request.entry)
        }
    }

    private func selectSource(_ source: MediaSource) {
        guard source.id != library.selectedID else { return }
        guard source.kind == .emby, let address = source.emby?.serverAddress,
              LocalNetworkPermissionProbe.isLocalAddress(address) else {
            library.select(source.id)
            return
        }
        Task {
            if await LocalNetworkPermissionProbe.check(address) == .denied {
                activeAlert = .localNetwork
            } else {
                library.select(source.id)
            }
        }
    }

    private func refreshRoutes(_ id: UUID) {
        guard refreshingRoutes.insert(id).inserted else { return }
        Task {
            defer { refreshingRoutes.remove(id) }
            do {
                try await library.refreshEmbyRoutes(id)
            } catch {
                activeAlert = .refreshRoutes(error.localizedDescription)
            }
        }
    }

    private var addMenu: some View {
        Menu {
            if !library.sources.contains(where: { $0.kind == .photos }) {
                Button("相册视频", systemImage: "play.rectangle.on.rectangle") { addPhotos() }
            }
            if !library.sources.contains(where: { $0.kind == .local }) {
                Button("本地视频", systemImage: "folder") { addLocalVideos() }
            }
            Button { isShowingEmbyEditor = true } label: {
                Label("Emby", image: "EmbyLogo")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("添加来源")
    }

    private func addPhotos() {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if status == .authorized || status == .limited {
                library.addDeviceSource(kind: .photos, name: VesperLocalization.string("相册视频"))
            } else { activeAlert = .addSource }
        }
    }

    private func addLocalVideos() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
            library.addDeviceSource(
                kind: .local,
                name: VesperLocalization.string("本地视频")
            )
        } catch {
            activeAlert = .addSource
        }
    }
}

private struct SourceListRow: View {
    @EnvironmentObject private var library: SourceLibrary
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @AppStorage("appearance.accent") private var accent = "vesper"
    let source: MediaSource
    let isSelected: Bool
    let latency: Int?
    let select: () -> Void
    @State private var summary: EmbySourceSummary?

    private var rowHeight: CGFloat { CGFloat(layout[.sourceListRowHeight]) }
    private var iconTop: CGFloat { CGFloat(layout[.sourceListIconTop]) }
    private var iconLeading: CGFloat { CGFloat(layout[.sourceListIconLeading]) }
    private var iconBottom: CGFloat { CGFloat(layout[.sourceListIconBottom]) }
    private var iconTrailing: CGFloat { CGFloat(layout[.sourceListIconTrailing]) }
    private var iconSide: CGFloat { max(0, rowHeight - iconTop - iconBottom) }

    private var title: String {
        switch source.kind {
        case .local: VesperLocalization.string("本地视频")
        case .photos: VesperLocalization.string("相册视频")
        default: source.name
        }
    }

    private var routeTitle: String? {
        guard let configuration = source.emby else { return nil }
        let current = configuration.serverAddress
        guard EmbyRouteOptions.key(current) != EmbyRouteOptions.key(configuration.primaryRoute) else {
            return VesperLocalization.string("主线路")
        }
        return configuration.alternateRouteNames?[EmbyRouteOptions.key(current)] ?? URLComponents(string: current)?.host ?? current
    }

    private typealias LatencyColorStop = (milliseconds: Int, red: Double, green: Double, blue: Double)
    private static let lightLatencyColors: [LatencyColorStop] = [
        (30, 0.08, 0.45, 0.24),
        (100, 0.34, 0.43, 0.08),
        (200, 0.65, 0.32, 0.04),
        (400, 0.73, 0.15, 0.18),
    ]
    private static let darkLatencyColors: [LatencyColorStop] = [
        (30, 0.31, 0.85, 0.52),
        (100, 0.70, 0.86, 0.27),
        (200, 1.00, 0.64, 0.26),
        (400, 1.00, 0.38, 0.41),
    ]

    private var latencyColor: Color {
        guard let latency else { return .secondary }
        let stops = colorScheme == .dark ? Self.darkLatencyColors : Self.lightLatencyColors
        for (lower, upper) in zip(stops, stops.dropFirst()) where latency <= upper.milliseconds {
            let fraction = Double(max(latency, lower.milliseconds) - lower.milliseconds)
                / Double(upper.milliseconds - lower.milliseconds)
            return Color(
                red: lower.red + (upper.red - lower.red) * fraction,
                green: lower.green + (upper.green - lower.green) * fraction,
                blue: lower.blue + (upper.blue - lower.blue) * fraction
            )
        }
        guard let last = stops.last else { return .secondary }
        return Color(red: last.red, green: last.green, blue: last.blue)
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 0) {
                icon
                    .frame(width: iconSide, height: iconSide)
                    .padding(.top, iconTop)
                    .padding(.leading, iconLeading)
                    .padding(.bottom, iconBottom)
                    .padding(.trailing, iconTrailing)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 0) {
                        Text(verbatim: title)
                        if let routeTitle {
                            Text(verbatim: " · \(routeTitle)").foregroundStyle(.secondary)
                            Text(verbatim: " · ").foregroundStyle(.secondary)
                            Text(verbatim: latency.map { "\($0) ms" } ?? "—")
                                .monospacedDigit()
                                .foregroundStyle(latencyColor)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                    Text(verbatim: countLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(verbatim: lastPlayedLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.trailing, 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(VesperTheme.accent(accent))
                        .padding(.trailing, 14)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: source.emby?.serverAddress) {
            guard source.kind == .emby else { summary = nil; return }
            if library.connectionStatus(for: source) != .checking {
                library.verifyEmbyConnection(source.id)
            }
            let updatedSummary = try? await EmbyRepository.shared.sourceSummary(for: source)
            if !Task.isCancelled { summary = updatedSummary }
        }
    }

    @ViewBuilder private var icon: some View {
        if source.kind == .emby {
            if let data = source.emby?.iconData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: min(8, iconSide * 0.18)))
            } else {
                Image("EmbyLogo").resizable().scaledToFit().padding(iconSide * 0.06)
            }
        } else {
            Image(systemName: source.kind == .photos ? "play.rectangle.on.rectangle" : "folder")
                .resizable()
                .scaledToFit()
                .padding(iconSide * 0.2)
                .foregroundStyle(VesperTheme.accent(accent))
        }
    }

    private var countLine: String {
        guard source.kind == .emby else { return "—" }
        guard let summary else { return "\(VesperLocalization.string("电影")) — · \(VesperLocalization.string("剧集")) —" }
        return "\(VesperLocalization.string("电影")) \(summary.movieCount) · \(VesperLocalization.string("剧集")) \(summary.seriesCount)"
    }

    private var lastPlayedLine: String {
        guard let date = summary?.lastPlayed else { return "\(VesperLocalization.string("上次播放")) —" }
        return "\(VesperLocalization.string("上次播放")) \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
