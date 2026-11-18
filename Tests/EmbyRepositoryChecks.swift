import Foundation

@main
struct EmbyRepositoryChecks {
    @MainActor static func main() async throws {
        UserDefaults.standard.set(true, forKey: EmbyUserAgentPolicy.enabledKey)
        UserDefaults.standard.set("CustomVesper", forKey: EmbyUserAgentPolicy.nameKey)
        UserDefaults.standard.set("2.0", forKey: EmbyUserAgentPolicy.versionKey)
        let configuration = EmbySourceConfiguration(title: "家庭影院", note: "媒体服务器", serverAddress: CommandLine.arguments[1] + "/proxy",
                                                     username: "test", serverID: "server", userID: "user",
                                                     customHeaders: [:])
        let client = try EmbyAPIClient(configuration: configuration, token: "secret", deviceID: "stable-device")
        let repository = EmbyRepository(clientProvider: { _ in client })
        let source = MediaSource(id: UUID(), name: configuration.title, kind: .emby, behavior: .empty, emby: configuration)
        let roots = try await repository.rootItems(for: source)
        precondition(roots.count == 1 && roots[0].isContainer)
        let libraries = try await repository.mediaLibraries(for: source)
        precondition(libraries.map(\.id.localID) == ["library"] && libraries[0].isContainer)
        let latest = try await repository.latestMedia(for: source, libraryID: libraries[0].id.localID)
        precondition(latest.count == 20 && latest.first?.id.localID == "movie-0")
        let items = try await repository.items(for: source, parentID: "library", startIndex: 100)
        precondition(items.count == 1 && !items[0].isContainer)
        var item = items[0]
        let thumbnail = await repository.thumbnailData(for: item, source: source)
        precondition(thumbnail != nil)
        precondition(item.id.sourceID == source.id && item.id.localID == "movie")
        precondition(item.resumePosition == 30 && item.duration == 600)
        let details = try await repository.details(for: item, source: source)
        precondition(details.versions.count == 2 && details.video.synopsis == "A movie")
        item.embyMediaSourceID = "v2"
        let resource = try await repository.playbackResource(item: item, source: source, position: 30)
        precondition(resource.mediaSourceID == "v2" && resource.resumePosition == 30)
        precondition(resource.subtitles.count == 1 && resource.subtitles[0].url.path.contains("/v2/Subtitles/2/"))
        precondition(resource.resource.headers["User-Agent"] == "CustomVesper/2.0")
        precondition(resource.resource.headers["Authorization"]?.hasPrefix("Emby UserId=\"user\"") == true)
        precondition(resource.resource.headers["X-Emby-Token"] == "secret")
        precondition(resource.resource.url.absoluteString.contains("MediaSourceId=v2"))
        let stream = try await repository.transcodedResource(item: item, source: source, position: 200)
        precondition(stream.resource.timelineOffset == 200 && stream.resource.originalDuration == 600)
        precondition(stream.resource.url.path == "/proxy/emby/Videos/movie/master.m3u8")
        let session = EmbyPlaybackSession(source: source, item: item, playSessionID: "session-client",
                                           mediaSourceID: "v2", repository: repository)
        session.update(position: 30, paused: false, rate: 1, remembersProgress: true, ready: false)
        session.update(position: 30, paused: false, rate: 1, remembersProgress: true, ready: true)
        for _ in 0..<200 { session.update(position: 31, paused: false, rate: 1, remembersProgress: true, ready: true) }
        session.update(position: 31, paused: true, rate: 1, remembersProgress: true, ready: true)
        session.didSeek(to: 120, paused: true)
        if let finishing = session.finish() { await finishing.value }
        if let finishing = session.finish() { await finishing.value }
        let noResume = EmbyPlaybackSession(source: source, item: item, playSessionID: "session-no-position",
                                           mediaSourceID: "v2", repository: repository)
        noResume.update(position: 30, paused: false, rate: 1, remembersProgress: false, ready: true)
        noResume.update(position: 31, paused: true, rate: 1, remembersProgress: false, ready: true)
        if let finishing = noResume.finish() { await finishing.value }
        let response = try await client.get("Events")
        let events = response["Items"] as! [[String: Any]]
        let reports = events.filter { ($0["body"] as? [String: Any])?["PlaySessionId"] as? String == "session-client" }
        precondition(reports.count == 4, "Reports must be throttled and stop idempotent")
        precondition(reports.map { $0["path"] as! String } == ["Sessions/Playing", "Sessions/Playing/Progress", "Sessions/Playing/Progress", "Sessions/Playing/Stopped"])
        let final = reports.last!["body"] as! [String: Any]
        precondition((final["PositionTicks"] as! NSNumber).int64Value == 1_200_000_000)
        let noResumeReports = events.compactMap { event -> [String: Any]? in
            guard let body = event["body"] as? [String: Any],
                  body["PlaySessionId"] as? String == "session-no-position" else { return nil }
            return body
        }
        precondition(noResumeReports.count == 3 && noResumeReports.allSatisfy { $0["PositionTicks"] == nil })
        let snapshot = try JSONEncoder().encode(source)
        let snapshotString = String(decoding: snapshot, as: UTF8.self)
        precondition(!snapshotString.contains("secret") && !snapshotString.lowercased().contains("password"))
        let restoredSource = try JSONDecoder().decode(MediaSource.self, from: snapshot)
        precondition(restoredSource == source)
        let oldSourceJSON = "{\"id\":\"\(UUID().uuidString)\",\"name\":\"Old\",\"kind\":\"demo\",\"behavior\":\"content\"}"
        let migrated = try JSONDecoder().decode(MediaSource.self, from: Data(oldSourceJSON.utf8))
        precondition(migrated.emby == nil && migrated.folderBookmark == nil)
        precondition(events.contains { event in
            let query = event["query"] as? [String: [String]]
            return event["method"] as? String == "DELETE" && query?["PlaySessionId"] == ["session-client"] && query?["DeviceId"] == ["stable-device"]
        })
        print("Emby repository/session checks passed: hierarchy, versions, resume, sidecars, transcode timeline, throttling, ordered reports and scoped cleanup.")
    }
}
