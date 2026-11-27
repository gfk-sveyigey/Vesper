"""Exercise production receipt/acknowledgment logic without an Apple SDK."""
import os
import plistlib
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]

class VideoImportPresentationTests(unittest.TestCase):
    def test_documents_are_visible_and_external_open_still_stages_a_copy(self):
        with (ROOT / 'Info.plist').open('rb') as file:
            configuration = plistlib.load(file)
        self.assertIs(configuration['LSSupportsOpeningDocumentsInPlace'], True)
        self.assertIs(configuration['UIFileSharingEnabled'], True)
        self.assertTrue(configuration['CFBundleDocumentTypes'])
        delivery = (ROOT / 'Vesper/App/VesperFileDelivery.swift').read_text()
        self.assertIn('return FileDeliveryRouter.receive(url, origin: "app.open")', delivery)
        self.assertIn('origin: String, requiresCopy: Bool = true', delivery)

    def test_share_extension_is_embedded_and_uses_the_same_configurable_group(self):
        main = plistlib.loads((ROOT / 'Info.plist').read_bytes())
        share = plistlib.loads((ROOT / 'ShareExtension/Info.plist').read_bytes())
        entitlements = plistlib.loads((ROOT / 'Vesper/App/VesperAppGroup.entitlements').read_bytes())
        group = main['VesperAppGroupIdentifier']
        self.assertEqual(group, share['VesperAppGroupIdentifier'])
        self.assertEqual([group], entitlements['com.apple.security.application-groups'])
        self.assertEqual(share['NSExtension']['NSExtensionPointIdentifier'], 'com.apple.share-services')
        self.assertIn('public.movie', share['NSExtension']['NSExtensionAttributes']['NSExtensionActivationRule'])
        project = (ROOT / 'Vesper.xcodeproj/project.pbxproj').read_text()
        self.assertIn('productType = "com.apple.product-type.app-extension"', project)
        self.assertIn('dstSubfolderSpec = 13;', project)
        self.assertEqual(project.count('VESPER_APP_GROUP = "";'), 2)
        self.assertEqual(project.count('CODE_SIGN_ENTITLEMENTS = "$(VESPER_APP_GROUP_ENTITLEMENTS)";'), 4)
        self.assertNotIn('CODE_SIGN_ENTITLEMENTS = Vesper/App/VesperAppGroup.entitlements;', project)

    def test_separate_deliveries_are_published_as_one_batch_and_acknowledged_after_handling(self):
        compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
        if not compiler:
            self.skipTest('Swift compiler unavailable')
        shims = r'''
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#if os(Linux)
extension URL {
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() {}
}
#endif
@MainActor enum AppLog { static var runtimeEntries: [String] = [] }
actor VideoImporter {
    static let shared = VideoImporter()
    enum Inspection: Sendable { case unreadable, notVideo, video(IncomingVideo) }
    func prepare(_ access: IncomingFileAccess, requiresCopy: Bool) throws -> IncomingFileAccess { access }
    func inspect(_ access: IncomingFileAccess) async -> Inspection {
        if access.url.lastPathComponent == "unreadable.mp4" { return .unreadable }
        if access.url.pathExtension == "txt" { return .notVideo }
        return .video(IncomingVideo(access: access, duration: 60, width: 1920, height: 1080, byteCount: 100))
    }
}
'''
        checks = r'''
import Foundation
@main struct Checks {
    @MainActor static func main() async throws {
        let receiver = IncomingVideoReceiver()
        receiver.receive(URL(fileURLWithPath: "/tmp/first.mp4"), requiresCopy: false)
        try await Task.sleep(for: .milliseconds(100))
        precondition(receiver.batches.isEmpty)
        receiver.receive(URL(fileURLWithPath: "/tmp/second.mp4"), requiresCopy: false)
        receiver.receive(URL(fileURLWithPath: "/tmp/not-video.txt"), requiresCopy: false)
        for _ in 0..<100 {
            if !receiver.batches.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(receiver.batches.count == 1)
        let reserved = receiver.batches.first!
        precondition(reserved.files.map(\.name) == ["first.mp4", "second.mp4"])
        precondition(receiver.nonVideoCount == 1)
        receiver.receive(URL(fileURLWithPath: "/tmp/third.mp4"), requiresCopy: false)
        for _ in 0..<100 {
            if receiver.batches.count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(receiver.batches.count == 2 && receiver.batches.first?.id == reserved.id)
        receiver.acknowledgeBatch(reserved.id)
        // Repeated onAppear is idempotent and must not consume the next batch.
        receiver.acknowledgeBatch(reserved.id)
        precondition(receiver.batches.count == 1)
        precondition(receiver.batches.first?.files.map(\.name) == ["third.mp4"])
        receiver.acknowledgeBatch(receiver.batches.first!.id)
        precondition(receiver.batches.isEmpty)

        receiver.receivePickedFiles(["readable.mp4", "unreadable.mp4", "not-video.txt"].map {
            IncomingFileAccess(url: URL(fileURLWithPath: "/tmp/" + $0))
        })
        for _ in 0..<100 {
            if !receiver.batches.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pickedBatch = receiver.batches.first!
        precondition(pickedBatch.automaticallySaves)
        precondition(pickedBatch.files.map(\.name) == ["readable.mp4"])
        precondition(pickedBatch.unreadableFileNames == ["unreadable.mp4"])
        precondition(receiver.nonVideoCount == 2)
        receiver.acknowledgeBatch(pickedBatch.id)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let staging = SharedVideoInbox.stagingDirectory(in: root, id: id)
        for index in 0..<2 {
            let slot = staging.appendingPathComponent(String(index))
            try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
            try Data([UInt8(index)]).write(to: slot.appendingPathComponent("same-name.mp4"))
        }
        await receiver.receiveSharedBatches(from: root)
        precondition(receiver.batches.isEmpty)
        try SharedVideoInbox.publish(staging, in: root, id: id)
        await receiver.receiveSharedBatches(from: root)
        await receiver.receiveSharedBatches(from: root)
        precondition(receiver.batches.count == 1)
        let files = receiver.batches.first!.files
        precondition(files.map(\.name) == ["same-name.mp4", "same-name.mp4"])
        precondition(files[0].url != files[1].url)
        receiver.acknowledgeBatch(receiver.batches.first!.id)
        withExtendedLifetime(files) {
            precondition(files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        }

        let abandoned = SharedVideoInbox.stagingDirectory(in: root, id: UUID())
        let fresh = SharedVideoInbox.stagingDirectory(in: root, id: UUID())
        for directory in [abandoned, fresh] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)],
                                              ofItemAtPath: abandoned.path)
        let unclaimed = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rejected = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: unclaimed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        withExtendedLifetime(files) {
            SharedVideoInbox.discardPublishedBatch(rejected)
            SharedVideoInbox.discardPublishedBatch(root.appendingPathComponent(id.uuidString))
            precondition(!FileManager.default.fileExists(atPath: rejected.path))
            precondition(FileManager.default.fileExists(atPath: unclaimed.path))
            precondition(files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
            precondition(SharedVideoInbox.clearTemporaryBatches(in: root))
            precondition(files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        }
        precondition(!FileManager.default.fileExists(atPath: abandoned.path))
        precondition(!FileManager.default.fileExists(atPath: unclaimed.path))
        precondition(FileManager.default.fileExists(atPath: fresh.path))
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'IncomingVideo.swift').write_text(
                (ROOT / 'Vesper/Infrastructure/Sources/IncomingVideo.swift').read_text().replace('import Combine', ''))
            (folder / 'Shims.swift').write_text(shims)
            (folder / 'Checks.swift').write_text(checks)
            subprocess.run([compiler, '-swift-version', '6', str(folder / 'IncomingVideo.swift'),
                            str(ROOT / 'ShareExtension/SharedVideoInbox.swift'),
                            str(folder / 'Shims.swift'), str(folder / 'Checks.swift'), '-o', str(folder / 'checks')],
                           check=True, capture_output=True, text=True)
            subprocess.run([str(folder / 'checks')], check=True, capture_output=True, text=True)

    def test_signed_app_group_detection_picks_the_same_common_group_in_both_processes(self):
        compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
        if not compiler:
            self.skipTest('Swift compiler unavailable')

        def executable(groups):
            payload = plistlib.dumps({'com.apple.security.application-groups': groups})
            blob = struct.pack('>2I', 0xfade7171, 8 + len(payload)) + payload
            signature = struct.pack('>5I', 0xfade0cc0, 20 + len(blob), 1, 5, 20) + blob
            header = struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0)
            return header + struct.pack('<4I', 0x1d, 16, 48, len(signature)) + signature

        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            app = executable(['group.app-only', 'group.shared'])
            share = executable(['group.extension-only', 'group.shared'])
            (folder / 'app').write_bytes(app)
            (folder / 'share').write_bytes(share)
            (folder / 'truncated').write_bytes(share[:-1])
            checks = folder / 'Checks.swift'
            checks.write_text(r'''
import Foundation
@main struct Checks {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        func groups(_ name: String) throws -> Set<String> {
            SharedVideoInbox.signedGroups(in: try Data(contentsOf: folder.appendingPathComponent(name)))
        }
        let app = try groups("app")
        let share = try groups("share")
        let truncated = try groups("truncated")
        precondition(app == ["group.app-only", "group.shared"])
        precondition(share == ["group.extension-only", "group.shared"])
        precondition(truncated.isEmpty)
        precondition(SharedVideoInbox.preferredCommonGroup(app, share) == "group.shared")
        let multiple: Set<String> = ["group.shared", "group.app-only", "group.unrelated"]
        precondition(SharedVideoInbox.preferredCommonGroup(app, multiple) == "group.app-only")
        precondition(SharedVideoInbox.preferredCommonGroup(multiple, app) == "group.app-only")
        precondition(SharedVideoInbox.preferredCommonGroup(app, ["group.unrelated"]) == nil)
    }
}
''')
            binary = folder / 'checks'
            subprocess.run([compiler, '-swift-version', '6', str(ROOT / 'ShareExtension/SharedVideoInbox.swift'),
                            str(checks), '-o', str(binary)], check=True)
            subprocess.run([str(binary), str(folder)], check=True)

    def test_presentation_guards(self):
        source = (ROOT / 'Vesper/Features/Navigation/AppNavigationView.swift').read_text()
        self.assertIn('guard scenePhase == .active, videoPickerDismissed', source)
        self.assertIn('.onChange(of: scenePhase, initial: true)', source)
        self.assertIn('.onChange(of: incomingVideos.batches.map(\\.id), initial: true)', source)
        self.assertIn('.onChange(of: incomingVideos.nonVideoCount, initial: true)', source)
        self.assertIn('if phase == .active { presentNextIncomingVideo() }', source)
        self.assertIn('playerPresentationDismissed, importPresentationHost.canPresent', source)
        self.assertNotIn('incomingVideos.takeNext()', source)
        self.assertIn('VideoImportSheet(file: file)', source)
        self.assertIn('incomingVideos.acknowledgeBatch(batch.id)', source)
        self.assertIn('.task(id: incomingPresentationRequest)', source)
        self.assertIn('return root.presentedViewController == nil', source)
        self.assertNotIn('controller.children.contains { hasPresentation(in: $0) }', source)

    def test_multiple_videos_save_before_presentation_and_single_preview_has_one_detent(self):
        nav = (ROOT / 'Vesper/Features/Navigation/AppNavigationView.swift').read_text()
        sheet = (ROOT / 'Vesper/Features/Import/VideoImportSheet.swift').read_text()
        route = nav.split('private func presentNextIncomingVideo()', 1)[1].split('private func startNextAutomaticImport()', 1)[0]
        save = nav.split('private func startNextAutomaticImport()', 1)[1].split('private var incomingPresentationRequest', 1)[0]
        self.assertLess(route.index('startNextAutomaticImport()'), route.index('guard scenePhase'))
        self.assertIn('incomingVideos.batches.first(where: \\.automaticallySaves)', save)
        self.assertIn('batch.unreadableFileNames.map', save)
        self.assertNotIn('videoPickerDismissed', save)
        self.assertNotIn('importPresentationHost', save)
        self.assertIn('previewBatch = batch', route)
        self.assertIn('for file in batch.files', save)
        self.assertIn('try await VideoImporter.shared.importVideo(file)', save)
        self.assertIn('pendingImportFailures.append(contentsOf: failures)', save)
        self.assertEqual(save.count('library.registerImportedVideos('), 1)
        self.assertIn('let file: IncomingVideo', sheet)
        self.assertIn('.presentationDetents([.custom(VideoImportDetent.self)])', sheet)
        self.assertIn('.presentationDragIndicator(.hidden)', sheet)

    def test_document_picker_delivers_all_selected_copies_in_its_callback(self):
        local = (ROOT / 'Vesper/Features/Media/LocalFilesView.swift').read_text()
        nav = (ROOT / 'Vesper/Features/Navigation/AppNavigationView.swift').read_text()
        receiver = (ROOT / 'Vesper/Infrastructure/Sources/IncomingVideo.swift').read_text()
        picker = local.split('struct VideoDocumentPicker:', 1)[1]
        self.assertIn('asCopy: true', picker)
        self.assertIn('picker.allowsMultipleSelection = true', picker)
        self.assertIn('onPick(urls.map { IncomingFileAccess(url: $0) })', picker)
        self.assertNotIn('urls.first', picker)
        delivery = nav.split('VideoDocumentPicker { files in', 1)[1].split('} onCancel:', 1)[0]
        self.assertLess(delivery.index('receivePickedFiles(files)'), delivery.index('isSelectingVideo = false'))
        self.assertIn('await inspectDeliveredBatch(files)', receiver)
        self.assertIn('let automaticallySaves = files.count > 1', receiver)

    def test_share_inbox_url_only_requests_reading_published_batches(self):
        extension = (ROOT / 'ShareExtension/VideoShareViewController.swift').read_text()
        delivery = (ROOT / 'Vesper/App/VesperFileDelivery.swift').read_text()
        self.assertIn('vesper://share-inbox', extension)
        stage = extension.split('private func stageVideos()', 1)[1].split('private func showMessage', 1)[0]
        self.assertLess(stage.index('SharedVideoInbox.publish'), stage.index('finish(batch)'))
        self.assertIn('if let failure {\n            SharedVideoInbox.discardPublishedBatch(batch)', extension)
        self.assertIn('.task(id: presentation.appeared)', extension)
        self.assertIn('override func viewDidAppear(_ animated: Bool)', extension)
        self.assertIn('var responder: UIResponder? = view', extension)
        self.assertIn('url.host == "share-inbox", url.path.isEmpty', delivery)
        self.assertIn('Task { await IncomingVideoReceiver.shared.receiveSharedBatches() }', delivery)

    def test_external_document_delivery_uses_swiftui_scene_routing(self):
        app = (ROOT / 'Vesper/App/VesperApp.swift').read_text()
        source = (ROOT / 'Vesper/Features/Player/PlayerInteraction.swift').read_text()
        delegate = source.split('final class VesperAppDelegate:', 1)[1].split('enum PlayerGestureRegion:', 1)[0]
        file_delivery = (ROOT / 'Vesper/App/VesperFileDelivery.swift').read_text()
        self.assertIn('.onOpenURL { FileDeliveryRouter.receive($0, origin: "swiftui.open") }', app)
        self.assertIn('private let fileDelivery = VesperFileDeliveryDelegate()', delegate)
        self.assertIn('fileDelivery.application(application, didFinishLaunchingWithOptions: launchOptions)', delegate)
        self.assertIn('fileDelivery.application(application, open: url, options: options)', delegate)
        self.assertNotIn('configurationForConnecting', delegate)
        self.assertNotIn('VesperFileSceneDelegate', file_delivery)
