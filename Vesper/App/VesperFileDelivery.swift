import UIKit

/// SwiftUI continues to own windows, navigation stacks and rendering. This
/// delegate supplies only the documented UIKit scene callbacks for file delivery.
@MainActor
final class VesperFileDeliveryDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        FileDeliveryLog.write("App 启动，build=\(build)")
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = VesperFileSceneDelegate.self
        }
        FileDeliveryLog.write("配置 Scene，待交付 URL 数量=\(options.urlContexts.count)")
        return configuration
    }
}

@MainActor
final class VesperFileSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // A cold launch delivers its URLs here, not in openURLContexts.
        FileDeliveryLog.write("Scene 连接，初始 URL 数量=\(connectionOptions.urlContexts.count)")
        receive(connectionOptions.urlContexts, origin: "scene.connect")
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        FileDeliveryLog.write("Scene 收到 URL 事件，数量=\(URLContexts.count)")
        receive(URLContexts, origin: "scene.open")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        FileDeliveryLog.write("Scene 已激活")
    }

    private func receive(_ contexts: Set<UIOpenURLContext>, origin: String) {
        for context in contexts.sorted(by: { $0.url.absoluteString < $1.url.absoluteString }) {
            FileDeliveryLog.write("文件交付 origin=\(origin) openInPlace=\(context.options.openInPlace)")
            IncomingVideoReceiver.shared.receive(context.url)
        }
    }
}

@MainActor
private enum FileDeliveryLog {
    static func write(_ message: String) {
        AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [VideoImport] \(message)")
    }
}
