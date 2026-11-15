import SwiftUI
import Photos

struct SourcesView: View {
    @EnvironmentObject private var library: SourceLibrary
    @AppStorage("navigation.icons") private var icons = "{}"
    @State private var isShowingError = false
    @State private var isShowingEmbyNotice = false

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
                Button("相册视频", systemImage: "photo.on.rectangle") {
                    AppLog.menuDiagnostic("sources.add action=photos")
                    addPhotos()
                }
            }
            if !library.sources.contains(where: { $0.kind == .local }) {
                Button("本地视频", systemImage: "folder") {
                    AppLog.menuDiagnostic("sources.add action=local")
                    addLocalVideos()
                }
            }
            Button("Emby", systemImage: "play.rectangle") {
                AppLog.menuDiagnostic("sources.add action=emby")
                isShowingEmbyNotice = true
            }
        } label: {
            Label("添加来源", systemImage: "plus.circle")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .controlSize(.large)
        .frame(width: 48, height: 48)
        .menuDiagnostics("sources.add")
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
