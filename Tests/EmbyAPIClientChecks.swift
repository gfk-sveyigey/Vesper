import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct EmbyAPIClientChecks {
    static func checkRouteRefresh() {
        let primary = "https://primary.example.com"
        let active = "https://active.example.com"
        let moved = "https://moved.example.com"
        let manual = "https://manual.example.com"
        let stale = "https://stale.example.com"
        var configuration = EmbySourceConfiguration(title: "", note: "", serverAddress: active, username: "")
        configuration.primaryRouteAddress = primary
        configuration.alternateAddresses = [primary, manual, active, stale]
        configuration.serverRouteAddresses = [active, stale]
        configuration.alternateRouteNames = [EmbyRouteOptions.key(active): "Active"]

        configuration.replaceServerRoutes([.init(name: "Different", address: active)])
        precondition(configuration.serverAddress == active)
        precondition(configuration.backupRoutes == [manual, active])
        precondition(configuration.alternateRouteNames?[EmbyRouteOptions.key(active)] == "Active")

        configuration.replaceServerRoutes([.init(name: "Active", address: moved)])
        precondition(configuration.serverAddress == moved)
        precondition(configuration.primaryRoute == primary)
        precondition(configuration.backupRoutes == [manual, moved])
        precondition(configuration.alternateRouteNames?[EmbyRouteOptions.key(moved)] == "Active")
    }

    static func main() async throws {
        let defaults = UserDefaults.standard
        let oldEnabled = defaults.object(forKey: EmbyUserAgentPolicy.enabledKey)
        let oldName = defaults.object(forKey: EmbyUserAgentPolicy.nameKey)
        let oldVersion = defaults.object(forKey: EmbyUserAgentPolicy.versionKey)
        defer {
            defaults.set(oldEnabled, forKey: EmbyUserAgentPolicy.enabledKey)
            defaults.set(oldName, forKey: EmbyUserAgentPolicy.nameKey)
            defaults.set(oldVersion, forKey: EmbyUserAgentPolicy.versionKey)
        }
        defaults.set(true, forKey: EmbyUserAgentPolicy.enabledKey)
        defaults.set("CustomVesper", forKey: EmbyUserAgentPolicy.nameKey)
        defaults.set("2.0", forKey: EmbyUserAgentPolicy.versionKey)
        let address = CommandLine.arguments[1]
        checkRouteRefresh()
        let configuration = EmbySourceConfiguration(title: "家庭影院", note: "测试备注", serverAddress: address + "/proxy",
                                                     username: "test", userID: "test-user",
                                                     customHeaders: ["X-Test": "present"])
        let client = try EmbyAPIClient(configuration: configuration, token: "secret +&token", deviceID: "stable-device")
        precondition(client.baseURL.path == "/proxy/emby")
        precondition(client.userAgent == "CustomVesper/2.0")
        defaults.set(false, forKey: EmbyUserAgentPolicy.enabledKey)
        var defaultConfiguration = configuration
        defaultConfiguration.customHeaders.removeValue(forKey: "User-Agent")
        let defaultClient = try EmbyAPIClient(configuration: defaultConfiguration, token: nil, deviceID: "stable-device")
        precondition(defaultClient.userAgent == EmbyUserAgentPolicy.defaultValue)
        let defaultRequest = try await defaultClient.get("Echo")
        precondition(defaultRequest["ua"] as? String == EmbyUserAgentPolicy.defaultValue)
        defaults.set(true, forKey: EmbyUserAgentPolicy.enabledKey)
        let imageHeaders = client.requestHeaders(accept: "image/*,*/*;q=0.8")
        precondition(imageHeaders["Accept"] == "image/*,*/*;q=0.8")
        precondition(imageHeaders["X-Emby-Token"] == "secret +&token")
        precondition(imageHeaders["Authorization"]?.hasPrefix("Emby UserId=\"test-user\"") == true)
        precondition(imageHeaders["Authorization"]?.contains("Token=") != true)
        precondition(imageHeaders["User-Agent"] == "CustomVesper/2.0")
        let playbackHeaders = client.playbackHeaders()
        precondition(playbackHeaders == ["User-Agent": "CustomVesper/2.0", "X-Test": "present"])
        let authenticatedStream = try client.resolveMediaURL("/emby/Videos/1/stream?static=true", includeToken: true)
        precondition(URLComponents(url: authenticatedStream, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "api_key", value: "secret +&token")) == true)
        do {
            _ = try client.resolveMediaURL("https://foreign.invalid/stream", includeToken: true)
            preconditionFailure("Playback token must not leave the configured origin")
        } catch {}
        let imageURL = client.imageURL(itemID: "1", tag: "cache-tag")!
        precondition(imageURL.absoluteString.contains("maxWidth=640"))
        precondition(imageURL.absoluteString.contains("quality=90"))
        precondition(!imageURL.absoluteString.contains("api_key"))

        let same = try EmbyAPIClient(configuration: .init(title: "T", note: "", serverAddress: address + "/proxy/emby/",
                                                         username: "U"), token: nil, deviceID: "D")
        precondition(same.baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "proxy/emby")
        let result = try await client.get("Echo", query: ["term": "a & b", "StartIndex": "100"])
        precondition(result["ua"] as? String == "CustomVesper/2.0")
        precondition(result["token"] as? String == "secret +&token")
        precondition(result["extra"] as? String == "present")
        precondition((result["identity"] as? String)?.contains("DeviceId=\"stable-device\"") == true)
        precondition(result["term"] as? String == "a & b")
        let post = try await client.send("Echo", method: "POST", body: EmbyJSON(["PositionTicks": Int64(123456789012)]))
        precondition((post["PositionTicks"] as? NSNumber)?.int64Value == 123456789012)
        _ = try await client.send("Empty", method: "POST")
        let auth = try await client.send("Users/AuthenticateByName", method: "POST",
                                         body: EmbyJSON(["Username": "alice", "Pw": "pw"]))
        precondition(auth["AccessToken"] as? String == "issued-token")
        try await client.delete("Empty", query: ["DeviceId": "D", "PlaySessionId": "P"])
        let items = try await client.get("Array")
        precondition((items["Items"] as? [[String: Any]])?.count == 1)
        for status in [401, 403, 404, 500] {
            do { _ = try await client.get("Status/\(status)"); preconditionFailure("Expected HTTP failure") }
            catch let error as EmbyError {
                switch (status, error) {
                case (401, .authentication), (403, .forbidden), (404, .notFound), (500, .server(500)): break
                default: preconditionFailure("Wrong HTTP classification")
                }
            }
        }
        let route = try client.resolveMediaURL("/emby/Videos/1/master.m3u8?StartTimeTicks=100")
        precondition(route.path == "/proxy/emby/Videos/1/master.m3u8")
        let query = URLComponents(url: route, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.first { $0.name == "api_key" } == nil)
        let normalized = try client.resolveMediaURL("/proxy/emby/Videos/1/master.m3u8")
        precondition(normalized.path == route.path)
        precondition(EmbyAPIClient.redacted("url?api_key=secret&name=test") == "url?api_key=[redacted]&name=test")
        let file = try client.mediaURL("Videos/1/stream", query: ["static": "true"])
        precondition(file.path == "/proxy/emby/Videos/1/stream")
        do { _ = try client.resolveMediaURL("https://foreign.invalid/steal"); preconditionFailure("Cross-origin credential leak") }
        catch EmbyError.invalidAddress { }
        for invalidHeaders in [["X-Emby-Token": "override"], ["User-Agent": "injected\r\nBad: value"],
                               ["X-Test": "injected\r\nBad: value"], ["Bad:Name": "value"]] {
            var invalid = configuration; invalid.customHeaders = invalidHeaders
            do { _ = try EmbyAPIClient(configuration: invalid, token: nil, deviceID: "D"); preconditionFailure("Invalid header accepted") }
            catch EmbyError.invalidHeader { }
        }
        do {
            _ = try EmbyAPIClient(configuration: .init(title: "Remote", note: "", serverAddress: "http://example.com",
                                                        username: "test"), token: nil, deviceID: "D")
            preconditionFailure("Remote HTTP must be rejected")
        } catch EmbyError.insecureRemoteHTTP { }
        let data = try JSONEncoder().encode(configuration)
        let restored = try JSONDecoder().decode(EmbySourceConfiguration.self, from: data)
        precondition(restored == configuration)
        print("Emby API checks passed: proxy paths, UA/headers, JSON/ticks, HTTP errors, URL authentication and credential boundary.")
    }
}
