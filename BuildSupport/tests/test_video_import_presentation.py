"""Exercise production receipt/acknowledgment logic without an Apple SDK."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]

class VideoImportPresentationTests(unittest.TestCase):
    def test_queue_is_consumed_only_after_display(self):
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
        receiver.receive(URL(fileURLWithPath: "/tmp/second.mp4"), requiresCopy: false)
        for _ in 0..<100 {
            if receiver.videos.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(receiver.videos.count == 2)
        let reserved = receiver.videos.first!
        // A reservation/rejected presentation doesn't remove either file.
        precondition(receiver.videos.first!.id == reserved.id)
        precondition(receiver.videos.count == 2)
        receiver.acknowledgePresented(reserved.id)
        precondition(receiver.videos.count == 1)
        precondition(receiver.videos.first!.name == "second.mp4")
        // Repeated onAppear is idempotent and must not consume the next file.
        receiver.acknowledgePresented(reserved.id)
        precondition(receiver.videos.count == 1)
        receiver.acknowledgePresented(receiver.videos.first!.id)
        precondition(receiver.videos.isEmpty)
        receiver.receive(URL(fileURLWithPath: "/tmp/not-video.txt"), requiresCopy: false)
        for _ in 0..<100 {
            if receiver.nonVideoCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(receiver.nonVideoCount == 1 && receiver.videos.isEmpty)
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
                            str(folder / 'Shims.swift'), str(folder / 'Checks.swift'), '-o', str(folder / 'checks')],
                           check=True, capture_output=True, text=True)
            subprocess.run([str(folder / 'checks')], check=True, capture_output=True, text=True)

    def test_presentation_guards(self):
        source = (ROOT / 'Vesper/Features/Navigation/AppNavigationView.swift').read_text()
        self.assertIn('guard scenePhase == .active, videoPickerDismissed', source)
        self.assertIn('.onChange(of: scenePhase, initial: true)', source)
        self.assertIn('.onChange(of: incomingVideos.videos.map(\\.id), initial: true)', source)
        self.assertIn('.onChange(of: incomingVideos.nonVideoCount, initial: true)', source)
        self.assertIn('if phase == .active { presentNextIncomingVideo() }', source)
        self.assertIn('playerPresentationDismissed, importPresentationHost.canPresent', source)
        self.assertIn('previewVideo = incomingVideos.videos.first', source)
        self.assertNotIn('incomingVideos.takeNext()', source)
        self.assertIn('incomingVideos.acknowledgePresented(file.id)', source)
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
