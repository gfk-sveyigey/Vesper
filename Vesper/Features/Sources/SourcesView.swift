import SwiftUI
import UIKit
import Photos
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var library: SourceLibrary
    @AppStorage("navigation.icons") private var icons = "{}"
    @State private var isImporting = false
    @State private var isShowingError = false
    @State private var isShowingEmbyNotice = false

    var body: some View {
        Group {
            if library.sources.isEmpty {
                VesperEmptyPage(title: "来源", message: "未配置来源", symbol: AppSection.sources.symbol) { addMenu }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VesperLargeTitle(title: "来源") { addMenu }
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
                    }
                    .padding(.bottom, 20)
                }
                .vesperImmersiveTitle("来源")
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
        SourceAddMenuButton(
            canAddPhotos: !library.sources.contains(where: { $0.kind == .photos }),
            canAddLocal: !library.sources.contains(where: { $0.kind == .local }),
            addPhotos: {
                Task {
                    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    if status == .authorized || status == .limited {
                        library.addDeviceSource(kind: .photos, name: VesperLocalization.string("相册视频"))
                    } else { isShowingError = true }
                }
            },
            addLocal: { isImporting = true },
            addEmby: { isShowingEmbyNotice = true }
        )
        .frame(width: 44, height: 44)
    }
}

/// The native button owns the menu and its presentation anchor directly.
private struct SourceAddMenuButton: UIViewRepresentable {
    let canAddPhotos: Bool
    let canAddLocal: Bool
    let addPhotos: @MainActor () -> Void
    let addLocal: @MainActor () -> Void
    let addEmby: @MainActor () -> Void
    @Environment(\.locale) private var locale

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(systemName: "plus.circle")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        configuration.cornerStyle = .capsule
        button.configuration = configuration
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.accessibilityLabel = VesperLocalization.string("添加来源")
        var actions: [UIMenuElement] = []
        if canAddPhotos {
            actions.append(UIAction(title: VesperLocalization.string("相册视频"), image: UIImage(systemName: "photo")) { _ in
                addPhotos()
            })
        }
        if canAddLocal {
            actions.append(UIAction(title: VesperLocalization.string("本地视频"), image: UIImage(systemName: "folder")) { _ in
                addLocal()
            })
        }
        actions.append(UIAction(title: "Emby", image: UIImage(systemName: "server.rack")) { _ in
            addEmby()
        })
        button.menu = UIMenu(children: actions)
    }
}
