import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var library: SourceLibrary
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var isImporting = false
    @State private var isShowingAddSourceDialog = false
    @State private var photoAccessFailed = false
    @State private var importFailed = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 0) {
                    VesperLargeTitle("来源")
                    Spacer(minLength: 8)
                    Button {
                        isShowingAddSourceDialog = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3.weight(.semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("添加媒体来源")
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
                }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if library.sources.isEmpty {
                ContentUnavailableView("未配置来源", systemImage: "externaldrive")
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(library.sources) { source in
                    Button { library.select(source.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: source.kind.symbol).foregroundStyle(.tint)
                            Text(LocalizedStringKey(source.kind.titleKey)).foregroundStyle(.primary)
                            Spacer()
                            if source.id == library.selectedID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(source.id == library.selectedID ? .isSelected : [])
                    .swipeActions {
                        Button("删除", role: .destructive) { library.remove(source.id) }
                    }
                }
            }
            if library.storageFailed { Text("来源设置保存失败").foregroundStyle(.red) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .vesperImmersiveTitle("来源")
        .confirmationDialog("添加媒体来源", isPresented: $isShowingAddSourceDialog, titleVisibility: .visible) {
            if !library.contains(.photos) {
                Button("相册视频") {
                    Task {
                        do { try await library.addPhotos() }
                        catch { photoAccessFailed = true }
                    }
                }
            }
            if !library.contains(.local) {
                Button("本地视频") { isImporting = true }
            }
            Button("Emby") {}.disabled(true)
            Button("取消", role: .cancel) {}
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else {
                if case .failure(let error) = result, (error as NSError).code != CocoaError.userCancelled.rawValue { importFailed = true }
                return
            }
            Task {
                do { try await library.importVideos(urls) }
                catch { importFailed = true }
            }
        }
        .alert("无法访问相册", isPresented: $photoAccessFailed) {
            Button("取消", role: .cancel) {}
            Button("打开设置") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
        } message: { Text("请在系统设置中允许访问相册视频。") }
        .alert("导入失败", isPresented: $importFailed) {
            Button("好", role: .cancel) {}
        } message: { Text("视频导入失败，请检查文件是否可用及剩余空间。") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, library.selectedSource?.kind == .photos { library.reload() }
        }
    }

}
