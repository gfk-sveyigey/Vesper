import SwiftUI
import UIKit

@main
struct VesperApp: App {
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    @AppStorage("appearance.accent") private var accent = "vesper"
    @AppStorage("language.code") private var languageCode = "system"

    init() {
        configureSystemBarMaterials()
        AppLog.info("app.started", category: .lifecycle)
    }

    private func configureSystemBarMaterials() {
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithTransparentBackground()
        navigationAppearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        navigationAppearance.backgroundColor = .clear
        UINavigationBar.appearance().standardAppearance = navigationAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance
        UINavigationBar.appearance().compactAppearance = navigationAppearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithTransparentBackground()
        tabAppearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        tabAppearance.backgroundColor = .clear
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }

    var body: some Scene {
        WindowGroup {
            AppNavigationView()
                .tint(VesperTheme.accent(accent))
                .preferredColorScheme(VesperTheme.colorScheme(appearanceMode))
                .environment(\.locale, VesperLocalization.locale(for: languageCode))
        }
    }
}
