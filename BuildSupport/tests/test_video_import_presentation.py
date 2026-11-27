"""Exercise production receipt/acknowledgment logic without an Apple SDK."""
import os
import plistlib
from pathlib import Path
import shutil
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

    def test_separate_deliveries_are_published_as_one_batch_and_acknowledged_after_display(self):
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
        receiver.acknowledgePresented(reserved.id)
        // Repeated onAppear is idempotent and must not consume the next batch.
        receiver.acknowledgePresented(reserved.id)
        precondition(receiver.batches.count == 1)
        precondition(receiver.batches.first?.files.map(\.name) == ["third.mp4"])
        receiver.acknowledgePresented(receiver.batches.first!.id)
        precondition(receiver.batches.isEmpty)

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
        receiver.acknowledgePresented(receiver.batches.first!.id)
        withExtendedLifetime(files) {
            precondition(files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        }
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

    def test_presentation_guards(self):
        source = (ROOT / 'Vesper/Features/Navigation/AppNavigationView.swift').read_text()
        self.assertIn('guard scenePhase == .active, videoPickerDismissed', source)
        self.assertIn('.onChange(of: scenePhase, initial: true)', source)
        self.assertIn('.onChange(of: incomingVideos.batches.map(\\.id), initial: true)', source)
        self.assertIn('.onChange(of: incomingVideos.nonVideoCount, initial: true)', source)
        self.assertIn('if phase == .active { presentNextIncomingVideo() }', source)
        self.assertIn('playerPresentationDismissed, importPresentationHost.canPresent', source)
        self.assertIn('if let batch = incomingVideos.batches.first {\n            previewBatch = batch', source)
        self.assertNotIn('incomingVideos.takeNext()', source)
        self.assertIn('VideoImportSheet(files: batch.files)', source)
        self.assertIn('incomingVideos.acknowledgePresented(batch.id)', source)
        self.assertIn('.task(id: incomingPresentationRequest)', source)
        self.assertIn('return root.presentedViewController == nil', source)
        self.assertNotIn('controller.children.contains { hasPresentation(in: $0) }', source)

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
