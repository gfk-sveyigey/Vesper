import Foundation
import AVFoundation
import UniformTypeIdentifiers
import Libavformat
import Libavutil
@preconcurrency import KSPlayer
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

    func inspect(_ access: IncomingFileAccess) -> Inspection {
        let url = access.url
        guard url.isFileURL else { return .unreadable }
        var result = Inspection.unreadable
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readable in
            guard (try? readable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let handle = try? FileHandle(forReadingFrom: readable) else { return }
            defer { try? handle.close() }
            // Opening the handle alone does not prove that the provider can read data.
            do { _ = try handle.read(upToCount: 1) }
            catch { return }
            guard Self.isVideoType(readable) else { result = .notVideo; return }
            // Inspect actual streams, not just the filename. FFmpeg also handles
            // MKV/WebM, which AVFoundation may not recognize on iOS.
            var context = avformat_alloc_context()
            var options: OpaquePointer?
            av_dict_set(&options, "protocol_whitelist", "file,crypto,data", 0)
            av_dict_set(&options, "probesize", "5000000", 0)
            av_dict_set(&options, "analyzeduration", "3000000", 0)
            defer { av_dict_free(&options); avformat_close_input(&context) }
            guard avformat_open_input(&context, readable.path, nil, &options) >= 0,
                  let opened = context,
                  avformat_find_stream_info(opened, nil) >= 0 else { result = .notVideo; return }
            if let name = opened.pointee.iformat?.pointee.name {
                let demuxer = String(cString: name)
                let imageFormats: Set<String> = ["image2", "image2pipe", "gif", "apng", "ico"]
                if demuxer.hasSuffix("_pipe") || imageFormats.contains(demuxer) {
                    result = .notVideo
                    return
                }
            }
            var dimensions: (Int, Int)?
            for index in 0..<Int(opened.pointee.nb_streams) {
                guard let stream = opened.pointee.streams[index],
                      let codec = stream.pointee.codecpar,
                      codec.pointee.codec_type == AVMEDIA_TYPE_VIDEO,
                      stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0 else { continue }
                dimensions = (Int(codec.pointee.width), Int(codec.pointee.height))
                break
            }
            guard let dimensions else { result = .notVideo; return }
            let seconds = Double(opened.pointee.duration) / Double(AV_TIME_BASE)
            let size = try? readable.resourceValues(forKeys: [.fileSizeKey]).fileSize
            result = .video(IncomingVideo(access: access,
                duration: seconds.isFinite && seconds > 0 ? seconds : nil,
                width: dimensions.0, height: dimensions.1, byteCount: size.map(Int64.init)))
        }
        return error == nil ? result : .unreadable
    }

    func thumbnail(for file: IncomingVideo) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 500)
        do {
            let result = try await generator.image(at: .zero)
            return UIImage(cgImage: result.image).jpegData(compressionQuality: 0.85)
        } catch {
            // Unsupported containers use the GPL decoder below.
        }
        // Use the existing GPL decoder for containers the system cannot preview.
        if Task.isCancelled { return nil }
        if file.width <= 0 || file.height <= 0 { return nil }
        let controller = ThumbnailController(thumbnailCount: 1)
        guard let frames = try? await controller.generateThumbnail(for: file.url, thumbWidth: 600) else { return nil }
        return frames.first?.image.jpegData(compressionQuality: 0.85)
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
