import SwiftUI
import UIKit

@main
struct VesperApp: App {
    @UIApplicationDelegateAdaptor(VesperAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var incomingVideos = IncomingVideoReceiver.shared
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    @AppStorage("appearance.accent") private var accent = "vesper"
    @AppStorage("language.code") private var languageCode = "system"

    init() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        FileDeliveryLog.write("App 启动，build=\(build)，文件接收模式=SwiftUI原生")
        let opensInPlace = Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool ?? false
        FileDeliveryLog.write("安装包文件交付配置，openInPlace=\(opensInPlace)")

    }

    var body: some Scene {
        WindowGroup {
            AppNavigationView()
                .scrollIndicators(.hidden)
                .environmentObject(incomingVideos)
                .onOpenURL { FileDeliveryRouter.receive($0, origin: "swiftui.open") }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active {
                        FileDeliveryLog.write("SwiftUI Scene 已激活，文件接收模式=SwiftUI原生")
                    }
                }
                .tint(VesperTheme.accent(accent))
                .preferredColorScheme(VesperTheme.colorScheme(appearanceMode))
                .environment(\.locale, VesperLocalization.locale(for: languageCode))
        }
    }
}
