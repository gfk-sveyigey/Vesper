import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LocalFilesView<SourceMenu: View>: View {
    let source: MediaSource
    var directory = ""
    @ViewBuilder let sourceMenu: () -> SourceMenu
    @EnvironmentObject private var library: SourceLibrary
    @EnvironmentObject private var playback: PlaybackSession
    @EnvironmentObject private var incomingVideos: IncomingVideoReceiver
    @State private var entries: [LocalFileEntry] = []
    @State private var loading = true
    @State private var reloadGeneration = 0
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var isShowingError = false
    @State private var isNaming = false
    @State private var name = ""
    @State private var renameEntry: LocalFileEntry?
    @State private var deleteEntry: LocalFileEntry?
    @State private var movingEntry: LocalFileEntry?

    var body: some View {
        Group {
            if directory.isEmpty {
                VesperRootScrollView(title: "媒体") { files } actions: {
                    HStack(spacing: 12) {
                        HStack(spacing: 0) {
                            Button("选择视频", systemImage: "document.badge.plus") {
                                incomingVideos.selectVideo()
                            }
                            .labelStyle(.iconOnly)
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 44, height: 44)
                            .buttonStyle(.plain)
                            .disabled(busy)
                            Button("新建文件夹", systemImage: "folder.badge.plus", action: createFolder)
                                .labelStyle(.iconOnly)
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 44, height: 44)
                                .buttonStyle(.plain)
                                .disabled(busy)
                        }
                        .glassEffect(.regular.interactive(), in: .capsule)
                        sourceMenu()
                    }
                }
            } else {
                ScrollView { files.padding(.top, 12).padding(.bottom, 20) }
                    .navigationTitle(String(directory.split(separator: "/").last ?? ""))
                    .vesperNavigationStyle(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("新建文件夹", systemImage: "folder.badge.plus", action: createFolder)
                                .disabled(busy)
                        }
                    }
            }
        }
        .task(id: source.id) { await reload() }
        .refreshable { await reload() }
        .onChange(of: library.content) { _, content in
            if case .loaded = content { Task { await reload() } }
        }
        .alert(renameEntry == nil ? "新建文件夹" : "重命名", isPresented: $isNaming) {
            TextField("名称", text: $name)
            Button("取消", role: .cancel) { renameEntry = nil }
            Button("保存") { submitName() }
        } message: {
            if renameEntry?.isDirectory == false { Text("请输入完整文件名，包括扩展名。") }
        }
        .alert("删除项目？", isPresented: Binding(
            get: { deleteEntry != nil }, set: { if !$0 { deleteEntry = nil } }
        )) {
            if let entry = deleteEntry {
                Button("删除", role: .destructive) {
                    deleteEntry = nil
                    perform(affecting: entry, removesMedia: true) { root in
                        try await LocalFileStore.shared.delete(root: root, entry: entry)
                    }
                }
            }
            Button("取消", role: .cancel) { deleteEntry = nil }
        } message: {
            if deleteEntry?.isDirectory == true {
                Text("删除后无法恢复；删除文件夹会同时删除其中的所有文件。")
            } else {
                Text("删除后无法恢复。")
            }
        }
        .sheet(item: $movingEntry, onDismiss: { Task { await reload() } }) { entry in
            LocalMoveView(source: source, entry: entry, initialDirectory: directory) {
                stopPlayback(affectedBy: entry)
                library.reload()
            }
        }
        .alert("文件操作失败", isPresented: $isShowingError) {
            Button("好", role: .cancel) { }
        } message: { Text(verbatim: errorMessage ?? "") }
    }

    private var files: some View {
        LazyVStack(spacing: 12) {
            if loading && entries.isEmpty {
                ProgressView().padding(40)
            } else if entries.isEmpty {
                VesperCenteredEmptyContent(message: "来源中暂无媒体", symbol: AppSection.media.symbol)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                ForEach(entries) { entry in
                    Group {
                        if entry.isDirectory {
                            NavigationLink {
                                LocalFilesView(source: source, directory: entry.path, sourceMenu: sourceMenu)
                            } label: { row(entry) }
                            .contextMenu { fileActions(entry) }
                        } else {
                            Button {
                                let queue = entries.filter { !$0.isDirectory && VideoImporter.isVideoType(URL(fileURLWithPath: $0.name)) }
                                    .map(mediaItem)
                                playback.play(mediaItem(entry), in: source, queue: queue)
                            } label: { row(entry) }
                            .disabled(!VideoImporter.isVideoType(URL(fileURLWithPath: entry.name)))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func row(_ entry: LocalFileEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.isDirectory {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color("VesperSecondaryBackground"))
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 48)).foregroundStyle(.tint)
                    }
            } else if VideoImporter.isVideoType(URL(fileURLWithPath: entry.name)) {
                MediaThumbnail(source: source, item: mediaItem(entry), playback: playback)
                    .modifier(MediaThumbnailMenu(source: source, item: mediaItem(entry), playback: playback) { fileActions(entry) })
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color("VesperSecondaryBackground"))
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        Image(systemName: "doc")
                            .font(.largeTitle).foregroundStyle(.secondary)
                    }
            }
            Text(verbatim: entry.isDirectory ? entry.name : (entry.name as NSString).deletingPathExtension)
                .font(.headline).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(verbatim: entry.name))
    }

    @ViewBuilder
    private func fileActions(_ entry: LocalFileEntry) -> some View {
        Section {
            Button("重命名", systemImage: "pencil") {
                renameEntry = entry
                name = entry.name
                isNaming = true
            }
            Button("移动", systemImage: "folder") { movingEntry = entry }
            Button("删除", systemImage: "trash", role: .destructive) { deleteEntry = entry }
        }
    }

    private func mediaItem(_ entry: LocalFileEntry) -> MediaItem {
        MediaItem(id: MediaID(sourceID: source.id, localID: entry.path),
                  title: (entry.name as NSString).deletingPathExtension, resource: nil)
    }

    private func createFolder() {
        renameEntry = nil
        name = ""
        isNaming = true
    }

    private func submitName() {
        let proposedName = name
        let entry = renameEntry
        renameEntry = nil
        perform(affecting: entry) { root in
            if let entry {
                try await LocalFileStore.shared.rename(root: root, entry: entry, name: proposedName)
            } else {
                try await LocalFileStore.shared.createFolder(root: root, directory: directory, name: proposedName)
            }
        }
    }

    private func perform(affecting entry: LocalFileEntry?, removesMedia: Bool = false, operation: @escaping (URL) async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await operation(source.localFolderURL())
                if let entry {
                    stopPlayback(affectedBy: entry)
                    if removesMedia {
                        playback.removePlaybackData(sourceID: source.id, path: entry.path, includingDescendants: entry.isDirectory)
                    }
                }
                library.reload()
                await reload()
            } catch { showError(error) }
        }
    }

    private func stopPlayback(affectedBy entry: LocalFileEntry) {
        guard let current = playback.currentItem?.id, current.sourceID == source.id,
              current.localID == entry.path || current.localID.hasPrefix(entry.path + "/") else { return }
        playback.stop()
    }

    private func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        loading = true
        defer { if generation == reloadGeneration { loading = false } }
        do {
            let result = try await LocalFileStore.shared.entries(root: source.localFolderURL(), directory: directory)
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            entries = result
        } catch {
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}

private struct LocalMoveView: View {
    let source: MediaSource
    let entry: LocalFileEntry
    let initialDirectory: String
    let onMoved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var directory = ""
    @State private var folders: [LocalFileEntry] = []
    @State private var busy = false
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var isShowingError = false

    private var canMoveHere: Bool {
        directory != initialDirectory && directory != entry.path && !directory.hasPrefix(entry.path + "/")
    }

    var body: some View {
        NavigationStack {
            SettingsPage {
                SettingsSection {
                    Text(verbatim: directory.isEmpty ? source.name : directory)
                        .font(.footnote).foregroundStyle(.secondary)
                    if !directory.isEmpty {
                        Button("上一级", systemImage: "arrow.up") {
                            directory = directory.split(separator: "/").dropLast().joined(separator: "/")
                        }
                    }
                    ForEach(folders) { folder in
                        Button { directory = folder.path } label: {
                            Label { Text(verbatim: folder.name) } icon: { Image(systemName: "folder") }
                        }
                    }
                    if loading { ProgressView() }
                }
            }
            .navigationTitle("移动")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("移到此处") { move() }.disabled(busy || loading || !canMoveHere)
                }
            }
            .disabled(busy)
            .task(id: directory) { await loadFolders() }
            .alert("文件操作失败", isPresented: $isShowingError) {
                Button("好", role: .cancel) { }
            } message: { Text(verbatim: errorMessage ?? "") }
        }
        .interactiveDismissDisabled(busy)
    }

    private func loadFolders() async {
        loading = true
        folders = []
        defer { loading = false }
        do {
            let result = try await LocalFileStore.shared.entries(root: source.localFolderURL(), directory: directory)
            guard !Task.isCancelled else { return }
            folders = result.filter { $0.isDirectory && $0.path != entry.path && !$0.path.hasPrefix(entry.path + "/") }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            isShowingError = true
        }
    }

    private func move() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await LocalFileStore.shared.move(root: source.localFolderURL(), entry: entry, directory: directory)
                onMoved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isShowingError = true
            }
        }
    }
}

/// Use the documented delegate and retain copy-mode delivery for file providers.
struct VideoDocumentPicker: UIViewControllerRepresentable {
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
