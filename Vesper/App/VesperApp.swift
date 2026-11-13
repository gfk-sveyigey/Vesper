import SwiftUI

@main
struct VesperApp: App {
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    @AppStorage("appearance.accent") private var accent = "vesper"

    init() {
        AppLog.info("app.started", category: .lifecycle)
    }

    var body: some Scene {
        WindowGroup {
            AppNavigationView()
                .tint(VesperTheme.accent(accent))
                .preferredColorScheme(VesperTheme.colorScheme(appearanceMode))
        }
    }
}
