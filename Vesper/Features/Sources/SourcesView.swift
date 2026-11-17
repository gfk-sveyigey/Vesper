import SwiftUI
import Photos
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var library: SourceLibrary
    @AppStorage("navigation.icons") private var icons = "{}"
    @State private var isShowingError = false
    @State private var isShowingEmbyNotice = false
    @State private var isShowingVideoPicker = false

    var body: some View {
        ZStack {
            if library.sources.isEmpty {
                VesperEmptyPage(title: "来源", message: "未配置来源", symbol: AppSection.sources.symbol) { addMenu }
            } else {
                VesperRootScrollView(title: "来源") {
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
        .fileImporter(
            isPresented: $isShowingVideoPicker,
            allowedContentTypes: [.movie]
        ) { result in
            switch result {
            case .success(let url):
                FileDeliveryLog.write("应用内文件选择成功，extension=\(url.pathExtension)")
                FileDeliveryRouter.receive(url, origin: "fileImporter")
            case .failure(let error):
                FileDeliveryLog.write("应用内文件选择未完成，error=\(error.localizedDescription)")
            }
        }
        .alert("无法添加来源", isPresented: $isShowingError) {
            Button("好", role: .cancel) { }
        } message: { Text("请检查相册访问权限或本地视频文件。") }
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
                Button("本地视频", systemImage: "folder") { addLocalVideos() }
            }
            Button("Emby", systemImage: "play.rectangle") { isShowingEmbyNotice = true }
            Divider()
            Button("选择视频（诊断）", systemImage: "doc.badge.gearshape") {
                FileDeliveryLog.write("打开应用内视频选择器")
                isShowingVideoPicker = true
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
