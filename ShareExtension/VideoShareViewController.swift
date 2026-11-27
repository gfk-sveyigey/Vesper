import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
private final class VideoSharePresentation: ObservableObject {
    @Published var appeared = false
    @Published var launchFailure: String?
}

final class VideoShareViewController: UIViewController {
    private var didFinish = false
    private var didResolveHandoff = false
    private let presentation = VideoSharePresentation()

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 0, height: 104)
        guard let extensionContext else { return }
        let providers = extensionContext.inputItems.compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
            .filter(SharedVideoTransfer.supports)
        let host = UIHostingController(rootView: VideoShareView(providers: providers, presentation: presentation) { [weak self] batch in
            guard let self else { return }
            if let batch {
                openVesper(batch: batch)
            } else {
                finish(cancelled: true)
            }
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentation.appeared = true
    }

    private func openVesper(batch: URL) {
        // Share extensions cannot call UIApplication.open directly.
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = view
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                let implementation: IMP? = application.method(for: selector)
                guard let implementation, let url = NSURL(string: "vesper://share-inbox") else { break }
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary,
                                                 (@convention(block) (Bool) -> Void)?) -> Void
                let open = unsafeBitCast(implementation, to: Open.self)
                open(application, selector, url, NSDictionary()) { @Sendable [weak self] opened in
                    Task { @MainActor in self?.finishHandoff(batch: batch, failure: opened ? nil : "rejected") }
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    self?.finishHandoff(batch: batch, failure: "timeout")
                }
                return
            }
            responder = current.next
        }
        finishHandoff(batch: batch, failure: "no-responder")
    }

    private func finishHandoff(batch: URL, failure: String?) {
        guard !didFinish, !didResolveHandoff else { return }
        didResolveHandoff = true
        if let failure {
            SharedVideoInbox.discardPublishedBatch(batch)
            presentation.launchFailure = failure
        } else {
            finish()
        }
    }

    private func finish(cancelled: Bool = false) {
        guard !didFinish else { return }
        didFinish = true
        if cancelled {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

private struct VideoShareView: View {
    let providers: [NSItemProvider]
    @ObservedObject var presentation: VideoSharePresentation
    let finish: (URL?) -> Void
    @State private var started = false
    @State private var message: LocalizedStringKey = ""
    @State private var showsMessage = false
    @State private var publishedBatch: URL?

    var body: some View {
        Image("Icon")
            .resizable()
            .scaledToFit()
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .accessibilityLabel("Vesper")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 18)
            .task(id: presentation.appeared) {
                guard presentation.appeared else { return }
                await stageVideos()
            }
            .alert("接收视频", isPresented: $showsMessage) {
                Button(publishedBatch == nil ? "关闭" : "继续") { finish(publishedBatch) }
            } message: {
                Text(message)
            }
            .alert("无法打开 Vesper", isPresented: Binding(
                get: { presentation.launchFailure != nil },
                set: { if !$0 { presentation.launchFailure = nil } }
            ), presenting: presentation.launchFailure) { _ in
                Button("关闭") { finish(nil) }
            } message: { reason in
                Text(verbatim: reason)
            }
    }

    private func stageVideos() async {
        guard !started else { return }
        started = true
        guard !providers.isEmpty else {
            showMessage("请选择支持的视频文件。")
            return
        }
        guard let root = SharedVideoInbox.root else {
            showMessage("无法访问 Vesper 的共享容器，请检查签名的 App Group。")
            return
        }
        let id = UUID()
        let staging = SharedVideoInbox.stagingDirectory(in: root, id: id)
        var copied = 0
        let batch: URL
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            guard let lease = SharedVideoBatchLease(staging) else {
                showMessage("无法读取此视频，请先将文件下载到本机后重试。")
                return
            }
            defer { withExtendedLifetime(lease) {} }
            for (index, provider) in providers.enumerated() {
                try Task.checkCancellation()
                let slot = staging.appendingPathComponent(String(index), isDirectory: true)
                if await SharedVideoTransfer.copy(provider, to: slot) { copied += 1 }
            }
            try Task.checkCancellation()
            guard copied > 0 else {
                showMessage("无法读取此视频，请先将文件下载到本机后重试。")
                return
            }
            batch = try SharedVideoInbox.publish(staging, in: root, id: id)
        } catch is CancellationError {
            return
        } catch {
            showMessage("无法读取此视频，请先将文件下载到本机后重试。")
            return
        }
        if copied == providers.count {
            finish(batch)
        } else {
            publishedBatch = batch
            showMessage("部分视频无法接收。")
        }
    }

    private func showMessage(_ value: LocalizedStringKey) {
        message = value
        showsMessage = true
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
