import SwiftUI

private struct VideoImportDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(context.maxDetentValue, max(400, context.dynamicTypeSize.isAccessibilitySize ? 620 : 530))
    }
}

struct VideoImportSheet: View {
    let files: [IncomingVideo]
    let play: (IncomingVideo) -> Void
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var thumbnail: UIImage?
    @State private var loadingThumbnail = true
    @State private var saving = false
    @State private var savedIDs: Set<UUID> = []
    @State private var saveErrors: [UUID: String] = [:]

    private var singleFile: IncomingVideo? { files.count == 1 ? files.first : nil }

    var body: some View {
        NavigationStack {
            Group {
                if let file = singleFile {
                    ScrollView { singlePreview(file) }
                } else {
                    List(files) { file in
                        batchRow(file)
                    }
                    .listStyle(.plain)
                    .safeAreaInset(edge: .bottom) {
                        saveButton
                            .controlSize(.large)
                            .padding(20)
                            .frame(maxWidth: .infinity)
                            .background(.bar)
                    }
                }
            }
            .navigationTitle("接收视频")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).disabled(saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .presentationDetents([.custom(VideoImportDetent.self), .large])
        .presentationDragIndicator(.visible)
    }

    private func singlePreview(_ file: IncomingVideo) -> some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.secondary.opacity(0.12))
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                } else if loadingThumbnail {
                    ProgressView()
                } else {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel("视频缩略图")
            Text(verbatim: file.name)
                .font(.headline).multilineTextAlignment(.center).textSelection(.enabled)
            Text(verbatim: details(for: file))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let saveError = saveErrors[file.id] {
                Text(verbatim: saveError).font(.footnote).foregroundStyle(.red)
            }
            Button { play(file) } label: {
                Label("直接播放", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(saving)
            saveButton
        }
        .controlSize(.large)
        .padding(20)
        .task(id: file.id) {
            let data = await VideoImporter.shared.thumbnail(for: file)
            guard !Task.isCancelled else { return }
            thumbnail = data.flatMap { UIImage(data: $0) }
            loadingThumbnail = false
        }
    }

    private func batchRow(_ file: IncomingVideo) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: file.name).font(.headline)
                Text(verbatim: details(for: file)).font(.caption).foregroundStyle(.secondary)
                if let error = saveErrors[file.id] {
                    Text(verbatim: error).font(.caption).foregroundStyle(.red)
                }
            }
        } icon: {
            Image(systemName: savedIDs.contains(file.id) ? "checkmark.circle.fill" : "film")
                .foregroundStyle(savedIDs.contains(file.id) ? Color.green : Color.secondary)
        }
        .padding(.vertical, 6)
    }

    private var saveButton: some View {
        Button(action: saveFiles) {
            HStack {
                if saving { ProgressView() }
                Label(saving ? "正在保存" : singleFile == nil ? "保存全部" : "保存文件",
                      systemImage: "square.and.arrow.down")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(saving)
    }

    private func saveFiles() {
        guard !saving else { return }
        let pending = files.filter { !savedIDs.contains($0.id) }
        let previouslySavedCount = savedIDs.count
        saving = true
        saveErrors = [:]
        Task {
            for file in pending {
                do {
                    _ = try await VideoImporter.shared.importVideo(file)
                    savedIDs.insert(file.id)
                    FileDeliveryLog.write("文件保存成功")
                } catch {
                    saveErrors[file.id] = error.localizedDescription
                    FileDeliveryLog.write("保存失败：\(error.localizedDescription)")
                }
            }
            if savedIDs.count > previouslySavedCount { saved() }
            saving = false
            if savedIDs.count == files.count { dismiss() }
        }
    }

    private func details(for file: IncomingVideo) -> String {
        var values: [String] = []
        if let duration = file.duration {
            let total = Int(duration)
            values.append(total >= 3600
                ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                : String(format: "%d:%02d", total / 60, total % 60))
        }
        if file.width > 0 && file.height > 0 { values.append("\(file.width) × \(file.height)") }
        if let bytes = file.byteCount {
            values.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        return values.joined(separator: " · ")
    }
}
