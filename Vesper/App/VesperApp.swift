import SwiftUI

@main
struct VesperApp: App {
    init() {
        AppLog.info("app.started", category: .lifecycle)
    }

    var body: some Scene {
        WindowGroup {
            AppNavigationView()
                .tint(Color("VesperAccent"))
        }
    }
}
