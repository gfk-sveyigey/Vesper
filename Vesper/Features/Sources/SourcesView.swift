import SwiftUI
import Photos
import UniformTypeIdentifiers
import UIKit

struct SourcesView: View {
    @EnvironmentObject private var library: SourceLibrary
    @AppStorage("navigation.icons") private var icons = "{}"
    @State private var isShowingError = false
    @State private var isShowingEmbyNotice = false
    @State private var isShowingVideoPicker = false
    @State private var hasVideoPickerDismissed = true
    @State private var pickedVideoAccess: IncomingFileAccess?

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
        .sheet(isPresented: $isShowingVideoPicker, onDismiss: videoPickerDismissed) {
            DiagnosticVideoPicker { access in
                pickedVideoAccess = access
                isShowingVideoPicker = false
                deliverPickedVideoIfReady()
            } onCancel: {
                isShowingVideoPicker = false
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
                FileDeliveryLog.write("打开原生文档选择器，诊断过滤类型=public.data，asCopy=true")
                pickedVideoAccess = nil
                hasVideoPickerDismissed = false
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

    private func videoPickerDismissed() {
        FileDeliveryLog.write("文档选择器已关闭，待处理文件=\(pickedVideoAccess != nil)")
        hasVideoPickerDismissed = true
        deliverPickedVideoIfReady()
    }

    private func deliverPickedVideoIfReady() {
        // UIKit can deliver didPickDocumentsAt either before or after SwiftUI's
        // onDismiss. Both callbacks must retry delivery once their event arrives.
        guard hasVideoPickerDismissed, let access = pickedVideoAccess else { return }
        pickedVideoAccess = nil
        FileDeliveryLog.write("文档选择与关闭均已完成，交付视频检查")
        // Keep the selected file accessible until the shared receiver owns it.
        // Preview presentation starts only after the picker sheet has dismissed.
        withExtendedLifetime(access) {
            FileDeliveryRouter.receive(access.url, origin: "documentPicker")
        }
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

/// A diagnostic control using UIKit's documented file-selection delegate.
/// Import a sandbox copy to also remove external in-place access as a variable.
private struct DiagnosticVideoPicker: UIViewControllerRepresentable {
    let onPick: (IncomingFileAccess) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        FileDeliveryLog.write("原生文档选择器已创建，delegate 已绑定")
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onCancel = onCancel
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (IncomingFileAccess) -> Void
        var onCancel: () -> Void

        init(onPick: @escaping (IncomingFileAccess) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            FileDeliveryLog.write("原生文档选择回调，文件数量=\(urls.count)")
            guard let url = urls.first else {
                onCancel()
                return
            }
            FileDeliveryLog.write("原生文档选择成功，extension=\(url.pathExtension)")
            onPick(IncomingFileAccess(url: url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            FileDeliveryLog.write("原生文档选择器已取消")
            onCancel()
        }
    }
}
