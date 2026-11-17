import SwiftUI
import UIKit

@main
struct VesperApp: App {
    @UIApplicationDelegateAdaptor(VesperFileDeliveryDelegate.self) private var fileDeliveryDelegate
    @StateObject private var incomingVideos = IncomingVideoReceiver.shared
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    @AppStorage("appearance.accent") private var accent = "vesper"
    @AppStorage("language.code") private var languageCode = "system"

    init() {
        // Customize only the text color; leave fonts, backgrounds and materials native.
        if let titleColor = UIColor(named: "VesperPrimaryText") {
            UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: titleColor]
            UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: titleColor]
        }
    }

    var body: some Scene {
        WindowGroup {
            AppNavigationView()
                .environmentObject(incomingVideos)
                .tint(VesperTheme.accent(accent))
                .preferredColorScheme(VesperTheme.colorScheme(appearanceMode))
                .environment(\.locale, VesperLocalization.locale(for: languageCode))
        }
    }
}
