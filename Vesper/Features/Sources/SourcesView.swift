import SwiftUI
import Photos
import UIKit

private enum SourcesAlert: Hashable, Identifiable {
    case addSource
    case localNetwork
    var id: Self { self }
}

struct SourcesView: View {
    var headerVisibilityChanged: (Bool) -> Void = { _ in }
    @EnvironmentObject private var library: SourceLibrary
    @State private var activeAlert: SourcesAlert?
    @State private var isShowingEmbyEditor = false
    @State private var editingEmby: MediaSource?

    private var orderedSources: [MediaSource] {
        library.sources.filter { $0.kind == .photos }
            + library.sources.filter { $0.kind == .local }
            + library.sources.filter { $0.kind != .photos && $0.kind != .local }
    }

    var body: some View {
        VesperRootScrollView(title: "来源") {
            if library.sources.isEmpty {
                VesperCenteredEmptyContent(message: "未配置来源", symbol: AppSection.sources.symbol)
            } else {
                VStack(spacing: 16) {
                    ForEach(orderedSources) { source in
                        Button { selectSource(source) } label: {
                            HStack(spacing: 12) {
                                if source.kind == .emby {
                                    Group {
                                        if let data = source.emby?.iconData, let image = UIImage(data: data) {
                                            Image(uiImage: image).resizable().scaledToFill()
                                        } else {
                                            Image("EmbyLogo").resizable().scaledToFit().padding(2)
                                        }
                                    }
                                    .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 7))
                                } else {
                                    Image(systemName: source.kind == .photos ? "play.rectangle.on.rectangle" : "folder")
                                        .frame(width: 36)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: source.name).foregroundStyle(.primary)
                                    if let note = source.emby?.note, !note.isEmpty {
                                        Text(verbatim: note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer()
                                if source.id == library.selectedID { Image(systemName: "checkmark") }
                            }
                            .padding(16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(source.id == library.selectedID ? .isSelected : [])
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                        .contextMenu {
                            if source.kind == .emby {
                                Button("编辑", systemImage: "pencil") { editingEmby = source }
                            }
                            Button("删除", systemImage: "trash", role: .destructive) { library.remove(source.id) }
                        }
                        .accessibilityAction(named: Text("删除")) { library.remove(source.id) }
                    }
                    if library.storageFailed { Text("来源设置保存失败").foregroundStyle(.red) }
                }
                .padding(.horizontal, 20)
            }
        } actions: {
            addMenu
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .addSource:
                Alert(title: Text("无法添加来源"), message: Text("请检查相册访问权限或本地视频文件。"),
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
        .sheet(item: $editingEmby) { source in EmbySourceEditor(source: source) }
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
