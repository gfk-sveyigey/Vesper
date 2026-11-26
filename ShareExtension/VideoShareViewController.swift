import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class VideoShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let extensionContext else { return }
        let providers = extensionContext.inputItems.compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
            .filter(SharedVideoTransfer.supports)
        let host = UIHostingController(rootView: VideoShareView(providers: providers) { [weak extensionContext] cancel in
            if cancel {
                extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            } else {
                extensionContext?.completeRequest(returningItems: nil)
            }
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

private struct VideoShareView: View {
    let providers: [NSItemProvider]
    let finish: (Bool) -> Void
    @State private var saving = false
    @State private var processed = 0
    @State private var result: LocalizedStringKey?
    @State private var staged = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if saving {
                    ProgressView(value: Double(processed), total: Double(max(1, providers.count)))
                        .accessibilityLabel("正在保存")
                } else if let result {
                    Text(result).multilineTextAlignment(.center)
                } else if providers.isEmpty {
                    Text("请选择支持的视频文件。")
                } else {
                    List(Array(providers.enumerated()), id: \.offset) { entry in
                        Label {
                            if let name = entry.element.suggestedName {
                                Text(verbatim: name).lineLimit(2)
                            } else {
                                Text("视频")
                            }
                        } icon: { Image(systemName: "film") }
                    }
                    .listStyle(.plain)
                }
            }
            .padding(20)
            .navigationTitle("接收视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(staged ? "关闭" : "取消") { finish(!staged) }
                        .disabled(saving)
                }
                if !staged {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("导入视频", action: stageVideos)
                            .disabled(saving || providers.isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func stageVideos() {
        guard !saving, !staged else { return }
        guard let root = SharedVideoInbox.root else {
            result = "无法访问 Vesper 的共享容器，请检查签名的 App Group。"
            return
        }
        saving = true
        processed = 0
        let id = UUID()
        let staging = SharedVideoInbox.stagingDirectory(in: root, id: id)
        Task {
            defer { saving = false }
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                var copied = 0
                for (index, provider) in providers.enumerated() {
                    let slot = staging.appendingPathComponent(String(index), isDirectory: true)
                    if await SharedVideoTransfer.copy(provider, to: slot) { copied += 1 }
                    processed += 1
                }
                guard copied > 0 else {
                    result = "无法读取此视频，请先将文件下载到本机后重试。"
                    return
                }
                try SharedVideoInbox.publish(staging, in: root, id: id)
                staged = true
                result = copied == providers.count ? "请打开 Vesper 继续导入。" : "部分视频无法接收，请打开 Vesper 导入其余视频。"
            } catch {
                result = "无法读取此视频，请先将文件下载到本机后重试。"
            }
        }
    }
}

private enum SharedVideoTransfer {
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]

    static func supports(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            provider.registeredTypeIdentifiers.contains(where: isMovieIdentifier)
    }

    @MainActor static func copy(_ provider: NSItemProvider, to slot: URL) async -> Bool {
        let name = provider.suggestedName
        for type in provider.registeredTypeIdentifiers where isMovieIdentifier(type) {
            let copied: Bool = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type) { @Sendable url, _ in
                    // The provider can delete its temporary file as soon as this callback returns.
                    continuation.resume(returning: url.map { copyFile($0, suggestedName: name, type: type, to: slot) } ?? false)
                }
            }
            if copied { return true }
        }
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return false }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { @Sendable item, _ in
                continuation.resume(returning: (item as? URL).map { copyFile($0, suggestedName: nil, type: nil, to: slot) } ?? false)
            }
        }
    }

    private static func isMovieIdentifier(_ identifier: String) -> Bool {
        identifier == "org.matroska.mkv" || identifier == "org.webmproject.webm" ||
            UTType(identifier)?.conforms(to: .movie) == true
    }

    private static func copyFile(_ url: URL, suggestedName: String?, type: String?, to slot: URL) -> Bool {
        guard url.isFileURL else { return false }
        let urlExtension = url.pathExtension.lowercased()
        let knownExtension = videoExtensions.contains(urlExtension) ||
            UTType(filenameExtension: urlExtension)?.conforms(to: .movie) == true
        let inferredExtension = type.flatMap { UTType($0)?.preferredFilenameExtension }
        guard let ext = knownExtension ? urlExtension : inferredExtension, !ext.isEmpty else { return false }
        let suggestion = suggestedName.map { ($0 as NSString).lastPathComponent }
        let basename = suggestion.flatMap {
            ($0 as NSString).pathExtension.lowercased() == ext ? ($0 as NSString).deletingPathExtension : $0
        } ?? url.deletingPathExtension().lastPathComponent
        let name = basename.isEmpty || basename.hasPrefix(".") ? "Video" : basename
        let destination = slot.appendingPathComponent(name).appendingPathExtension(ext)
        let manager = FileManager.default
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinatorError: NSError?
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readable in
            do {
                let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
                try manager.createDirectory(at: slot, withIntermediateDirectories: true)
                try manager.copyItem(at: readable, to: destination)
                copied = true
            } catch { }
        }
        if !copied || coordinatorError != nil { try? manager.removeItem(at: slot); return false }
        return true
    }
}
