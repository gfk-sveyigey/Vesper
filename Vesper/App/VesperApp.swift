import SwiftUI

@main
struct VesperApp: App {
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    @AppStorage("appearance.accent") private var accent = "vesper"
    @AppStorage("language.code") private var languageCode = "system"

    init() {
        AppLog.info("app.started", category: .lifecycle)
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
