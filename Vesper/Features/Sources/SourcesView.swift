import SwiftUI
import Photos
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var library: SourceLibrary
    @AppStorage("navigation.icons") private var icons = "{}"
    @State private var isImporting = false
    @State private var isShowingError = false
    @State private var isShowingEmbyNotice = false

    var body: some View {
        ZStack {
            if library.sources.isEmpty {
                VesperEmptyPage(title: "来源", message: "未配置来源", symbol: AppSection.sources.symbol) { addMenu }
            } else {
                VesperRootScrollView(title: "来源") { _ in
                    LazyVStack(spacing: 16) {
                        ForEach(library.sources) { source in
                            Button { library.select(source.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: source.kind == .photos ? "photo" : "folder")
                                        .frame(width: 28)
                                    Text(verbatim: source.name).foregroundStyle(.primary)
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
                                Button("删除", role: .destructive) { library.remove(source.id) }
                            }
                            .accessibilityAction(named: Text("删除")) { library.remove(source.id) }
                        }
                        if library.storageFailed { Text("来源设置保存失败").foregroundStyle(.red) }
                    }
                    .padding(.horizontal, 20)
                } actions: {
                    addMenu
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                library.addDeviceSource(kind: .local, name: VesperLocalization.string("本地视频"), bookmark: bookmark)
            } catch { isShowingError = true }
        }
        .alert("无法添加来源", isPresented: $isShowingError) {
            Button("好", role: .cancel) { }
        } message: { Text("请检查相册访问权限或重新选择本地文件夹。") }
        .alert("Emby", isPresented: $isShowingEmbyNotice) {
            Button("好", role: .cancel) { }
        } message: { Text("Emby 来源尚未接入。") }
    }

    private var addMenu: some View {
        Menu {
            if !library.sources.contains(where: { $0.kind == .photos }) {
                Button("相册视频", systemImage: "photo.on.rectangle") { addPhotos() }
            }
            if !library.sources.contains(where: { $0.kind == .local }) {
                Button("本地视频", systemImage: "folder") { isImporting = true }
            }
            Button("Emby", systemImage: "play.rectangle") { isShowingEmbyNotice = true }
        } label: {
            Label("添加来源", systemImage: "plus.circle")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    private func addPhotos() {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if status == .authorized || status == .limited {
                library.addDeviceSource(kind: .photos, name: VesperLocalization.string("相册视频"))
            } else { isShowingError = true }
        }
    }
}
