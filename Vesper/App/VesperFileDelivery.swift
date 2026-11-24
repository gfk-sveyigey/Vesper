import UIKit

/// SwiftUI owns windows and navigation; delegates receive external documents.
@MainActor
final class VesperFileDeliveryDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        FileDeliveryLog.write("App 启动，build=\(build)，参数=\(launchOptions?.keys.map(\.rawValue).sorted() ?? [])")
        if let url = launchOptions?[.url] as? URL {
            FileDeliveryRouter.receive(url, origin: "app.launch")
        }
        if let activities = launchOptions?[.userActivityDictionary] as? [AnyHashable: Any] {
            for case let activity as NSUserActivity in activities.values {
                _ = FileDeliveryRouter.receive(activity, origin: "app.launch.activity")
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        FileDeliveryLog.write("App 收到打开文件事件，参数=\(options.keys.map(\.rawValue).sorted())")
        let openInPlace = options[.openInPlace] as? Bool ?? false
        return FileDeliveryRouter.receive(url, origin: "app.open", requiresCopy: !openInPlace)
    }

    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        FileDeliveryRouter.receive(userActivity, origin: "app.activity")
    }

}

/// System wrappers can forward one document to both native and SwiftUI callbacks.
/// Merge those overlapping deliveries, but let the same callback deliver a later
/// intentional share of the same file again.
@MainActor
enum FileDeliveryRouter {
    private struct Receipt {
        let time: ContinuousClock.Instant
        var origins: Set<String>
    }
    private static var recent: [URL: Receipt] = [:]

    @discardableResult
    static func receive(_ url: URL, origin: String, requiresCopy: Bool = true) -> Bool {
        FileDeliveryLog.write("入口=\(origin) scheme=\(url.scheme ?? "nil") extension=\(url.pathExtension)")
        // A control event sent from Safari tests the same external URL callbacks
        // without depending on a file provider or document-type association.
        if url.scheme?.lowercased() == "vesper-import-diagnostic", url.host == "ping" {
            FileDeliveryLog.write("外部 URL 诊断成功，入口=\(origin)")
            return true
        }
        guard url.isFileURL else { return false }
        let now = ContinuousClock.now
        recent = recent.filter { $0.value.time.duration(to: now) < .seconds(2) }
        let key = url.standardizedFileURL
        if var previous = recent[key], !previous.origins.contains(origin) {
            previous.origins.insert(origin)
            recent[key] = previous
            FileDeliveryLog.write("合并同一文件的重叠交付，入口=\(origin)")
            return true
        }
        recent[key] = Receipt(time: now, origins: [origin])
        IncomingVideoReceiver.shared.receive(url, requiresCopy: requiresCopy)
        return true
    }

    @discardableResult
    static func receive(_ activity: NSUserActivity, origin: String) -> Bool {
        let info = activity.userInfo ?? [:]
        FileDeliveryLog.write("入口=\(origin) activityType=\(activity.activityType) keys=\(info.keys.map { String(describing: $0) }.sorted())")
        var urls = Set<URL>()
        collectFileURLs(in: info, depth: 0, into: &urls)
        if let url = activity.webpageURL, url.isFileURL { urls.insert(url) }
        for url in urls { receive(url, origin: origin) }
        return !urls.isEmpty
    }

    private static func collectFileURLs(in value: Any, depth: Int, into urls: inout Set<URL>) {
        guard depth < 5 else { return }
        if let url = value as? URL, url.isFileURL {
            urls.insert(url)
        } else if let text = value as? String, text.hasPrefix("file://"), let url = URL(string: text) {
            urls.insert(url)
        } else if let dictionary = value as? [AnyHashable: Any] {
            for item in dictionary.values { collectFileURLs(in: item, depth: depth + 1, into: &urls) }
        } else if let array = value as? [Any] {
            for item in array { collectFileURLs(in: item, depth: depth + 1, into: &urls) }
        }
    }
}

@MainActor
enum FileDeliveryLog {
    static func write(_ message: String) {
        AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [VideoImport] \(message)")
    }
}
