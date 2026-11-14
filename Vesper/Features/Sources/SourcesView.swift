import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var library: SourceLibrary
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var isImporting = false
    @State private var isAuthorizing = false
    @State private var photoAccessFailed = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 0) {
                    VesperLargeTitle("来源")
                    Menu {
                        if !library.contains(.photos) {
                            Button("相册视频", systemImage: "photo.on.rectangle") {
                                isAuthorizing = true
                                Task {
                                    defer { isAuthorizing = false }
                                    do { try await library.addPhotos() }
                                    catch { photoAccessFailed = true }
                                }
                            }
                        }
                        if !library.contains(.local) {
                            Button("本地视频", systemImage: "folder") {
                                isImporting = true
                            }
                        }
                        Button("Emby", systemImage: "server.rack") {}.disabled(true)
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("添加媒体来源")
                    .disabled(isAuthorizing || library.isImporting)
                    .padding(.trailing, 20)
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
                            if source.id == library.selectedID {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(source.id == library.selectedID ? .isSelected : [])
                    .swipeActions {
                        Button("删除", role: .destructive) { library.remove(source.id) }
                            .disabled(library.isImporting)
                    }
                    .contextMenu {
                        if source.kind == .local {
                            Button("导入视频", systemImage: "square.and.arrow.down") { isImporting = true }
                                .disabled(library.isImporting)
                        }
                    }
                }
            }
            if library.storageFailed { Text("来源设置保存失败").foregroundStyle(.red) }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .vesperImmersiveTitle("来源")
        .videoImporter(isPresented: $isImporting)
        .alert("无法访问相册", isPresented: $photoAccessFailed) {
            Button("取消", role: .cancel) {}
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        } message: {
            Text("请在系统设置中允许访问相册视频。")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, library.selectedSource?.kind == .photos { library.reload() }
        }
    }
}

/// Shared by Sources and Media; the native document picker grants scoped read access.
private struct VideoImporter: ViewModifier {
    @EnvironmentObject private var library: SourceLibrary
    @Binding var isPresented: Bool
    @State private var importFailed = false

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    Task {
                        do { try await library.importVideos(urls) }
                        catch { importFailed = true }
                    }
                case .failure(let error):
                    if (error as NSError).code != CocoaError.userCancelled.rawValue { importFailed = true }
                }
            }
            .overlay {
                if library.isImporting {
                    ProgressView("正在导入视频")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("导入失败", isPresented: $importFailed) {
                Button("好", role: .cancel) {}
            } message: {
                Text("视频导入失败，请检查文件是否可用及剩余空间。")
            }
    }
}

extension View {
    func videoImporter(isPresented: Binding<Bool>) -> some View {
        modifier(VideoImporter(isPresented: isPresented))
    }
}
