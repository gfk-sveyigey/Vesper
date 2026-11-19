import SwiftUI
import Photos
import UIKit

struct SourcesView: View {
    @EnvironmentObject private var library: SourceLibrary
    @AppStorage("navigation.icons") private var icons = "{}"
    @State private var isShowingError = false
    @State private var isShowingEmbyEditor = false
    @State private var editingEmby: MediaSource?

    var body: some View {
        VesperRootScrollView(title: "来源") {
            if library.sources.isEmpty {
                VesperCenteredEmptyContent(message: "未配置来源", symbol: AppSection.sources.symbol)
            } else {
                VStack(spacing: 16) {
                    ForEach(library.sources) { source in
                        Button { library.select(source.id) } label: {
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
                        .background(Color("VesperSecondaryBackground"), in: RoundedRectangle(cornerRadius: 20))
                        .contextMenu {
                            if source.kind == .emby {
                                Button("编辑", systemImage: "pencil") { editingEmby = source }
                            }
                            Button("删除", role: .destructive) { library.remove(source.id) }
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
        .alert("无法添加来源", isPresented: $isShowingError) {
            Button("好", role: .cancel) { }
        } message: { Text("请检查相册访问权限或本地视频文件。") }
        .sheet(isPresented: $isShowingEmbyEditor) { EmbySourceEditor(source: nil) }
        .sheet(item: $editingEmby) { source in EmbySourceEditor(source: source) }
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
            Image(systemName: "folder.badge.plus")
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
            } else { isShowingError = true }
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
            isShowingError = true
        }
    }
}
