import SwiftUI

private struct VideoImportDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        min(context.maxDetentValue, max(400, context.dynamicTypeSize.isAccessibilitySize ? 620 : 530))
    }
}

struct VideoImportSheet: View {
    let file: IncomingVideo
    let play: () -> Void
    let saved: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var thumbnail: UIImage?
    @State private var loadingThumbnail = true
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
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
                    Text(verbatim: details)
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let saveError {
                        Text(verbatim: saveError).font(.footnote).foregroundStyle(.red)
                    }
                    Button(action: play) {
                        Label("直接播放", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
                    Button {
                        saving = true
                        saveError = nil
                        Task {
                            do {
                                let url = try await VideoImporter.shared.importVideo(from: file.url)
                                AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [VideoImport] 文件保存成功")
                                saved(url)
                            } catch {
                                AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [VideoImport] 保存失败：\(error.localizedDescription)")
                                saveError = error.localizedDescription
                                saving = false
                            }
                        }
                    } label: {
                        HStack {
                            if saving { ProgressView() }
                            Label(saving ? "正在保存" : "保存文件", systemImage: "square.and.arrow.down")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(saving)
                }
                .controlSize(.large)
                .padding(20)
            }
            .navigationTitle("接收视频")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }.disabled(saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .presentationDetents([.custom(VideoImportDetent.self), .large])
        .presentationDragIndicator(.visible)
        .task(id: file.id) {
            let data = await VideoImporter.shared.thumbnail(for: file)
            guard !Task.isCancelled else { return }
            thumbnail = data.flatMap { UIImage(data: $0) }
            loadingThumbnail = false
        }
    }

    private var details: String {
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
