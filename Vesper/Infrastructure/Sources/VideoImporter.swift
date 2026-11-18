import Foundation
import AVFoundation
import UniformTypeIdentifiers
import PlaybackContracts
import VesperAetherBridge
import VesperVLCBridge
import UIKit

/// Serializes imports and keeps potentially large file copies off the main actor.
actor VideoImporter {
    static let shared = VideoImporter()
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]

    enum Inspection: Sendable {
        case unreadable, notVideo, video(IncomingVideo)
    }

    static func isVideoType(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased()) ||
            UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }

    /// Some Open In deliveries require copying before the provider revokes access.
    /// This is a temporary preview/playback resource, not a saved library item.
    func prepare(_ access: IncomingFileAccess, requiresCopy: Bool) throws -> IncomingFileAccess {
        guard requiresCopy else { return access }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("Vesper-import-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(access.url.lastPathComponent)
        do {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: access.url, options: [], error: &coordinationError) { readable in
                do {
                    guard (try readable.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                        throw ImportFailure.unreadable
                    }
                    try manager.copyItem(at: readable, to: destination)
                } catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            return IncomingFileAccess(url: destination, temporaryDirectory: directory)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    func inspect(_ access: IncomingFileAccess) async -> Inspection {
        let url = access.url
        guard url.isFileURL else { return .unreadable }
        defer { withExtendedLifetime(access) {} }
        var result = Inspection.unreadable
        var fallbackCopy: IncomingFileAccess?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readable in
            guard (try? readable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let handle = try? FileHandle(forReadingFrom: readable) else { return }
            defer { try? handle.close() }
            // Opening the handle alone does not prove that the provider can read data.
            do { _ = try handle.read(upToCount: 1) }
            catch { return }
            guard Self.isVideoType(readable) else { result = .notVideo; return }
            // Metadata comes through the isolated Aether FFmpeg boundary.
            guard let probe = try? AetherMediaProbe.inspect(readable), probe.hasVideo else {
                // libVLC parsing is async. Copy while the coordinator's read lease
                // is held; never carry its provider URL beyond this accessor.
                let manager = FileManager.default
                let directory = manager.temporaryDirectory.appendingPathComponent("Vesper-probe-\(UUID().uuidString)", isDirectory: true)
                do {
                    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                    let copy = directory.appendingPathComponent(readable.lastPathComponent)
                    try manager.copyItem(at: readable, to: copy)
                    fallbackCopy = IncomingFileAccess(url: copy, temporaryDirectory: directory)
                } catch { try? manager.removeItem(at: directory) }
                result = .notVideo
                return
            }
            let size = try? readable.resourceValues(forKeys: [.fileSizeKey]).fileSize
            result = .video(IncomingVideo(access: access,
                duration: probe.duration.isFinite && probe.duration > 0 ? probe.duration : nil,
                width: probe.width, height: probe.height, byteCount: size.map(Int64.init)))
        }
        guard error == nil else { return .unreadable }
        if let copy = fallbackCopy {
            defer { withExtendedLifetime(copy) {} }
            guard !Task.isCancelled, let probe = try? await VLCMediaProbe.inspect(copy.url), probe.hasVideo else { return .notVideo }
            let size = try? copy.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return .video(IncomingVideo(access: access,
                duration: probe.duration.isFinite && probe.duration > 0 ? probe.duration : nil,
                width: probe.width, height: probe.height, byteCount: size.map(Int64.init)))
        }
        return result
    }

    func thumbnail(for file: IncomingVideo) async -> Data? {
        defer { withExtendedLifetime(file.access) {} }
        return await thumbnail(at: file.url)
    }

    func thumbnail(at url: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 1350)
        do {
            let result = try await generator.image(at: .zero)
            return UIImage(cgImage: result.image).jpegData(compressionQuality: 0.85)
        } catch {
            // The fallback probe/thumbnail path creates no UI playback session.
        }
        if Task.isCancelled { return nil }
        return try? await VLCMediaProbe.thumbnail(url)
    }

    enum ImportFailure: LocalizedError {
        case unsupported, unreadable
        var errorDescription: String? {
            switch self {
            case .unsupported: "请选择支持的视频文件。"
            case .unreadable: "无法读取此视频，请先将文件下载到本机后重试。"
            }
        }
    }

    func importVideo(_ file: IncomingVideo) throws -> URL {
        // Retain the same access owner used by preview and playback throughout
        // the copy, rather than reconstructing a URL or reacquiring permission.
        let incoming = file.url
        guard incoming.isFileURL,
              Self.isVideoType(incoming) else {
            throw ImportFailure.unsupported
        }
        defer { withExtendedLifetime(file.access) {} }
        let manager = FileManager.default
        let documents = try manager.url(for: .documentDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let source = incoming.standardizedFileURL
        // Opening a video already in our library must not duplicate it.
        if source.deletingLastPathComponent() == documents.standardizedFileURL {
            guard manager.isReadableFile(atPath: source.path) else { throw ImportFailure.unreadable }
            return source
        }
        let staging = documents.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        var coordinationError: NSError?
        var copyError: Error?
        // Coordinates access with Files/iCloud and other document providers.
        NSFileCoordinator().coordinate(readingItemAt: incoming, options: [], error: &coordinationError) { readable in
            do {
                guard (try readable.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                    throw ImportFailure.unreadable
                }
                try manager.copyItem(at: readable, to: staging)
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var destination = documents.appendingPathComponent(source.lastPathComponent)
        var suffix = 2
        while manager.fileExists(atPath: destination.path) {
            destination = documents.appendingPathComponent("\(stem) (\(suffix)).\(ext)")
            suffix += 1
        }
        // Publish only a complete file; interrupted copies cannot appear as videos.
        try manager.moveItem(at: staging, to: destination)
        // iOS may deliver a private Inbox copy. External originals are never removed.
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL
        if source.deletingLastPathComponent() == inbox { try? manager.removeItem(at: source) }
        return destination
    }
}
