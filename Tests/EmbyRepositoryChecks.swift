import Foundation

@main
struct EmbyRepositoryChecks {
    @MainActor static func main() async throws {
        precondition(EmbyRouteOptions.unique(["https://EXAMPLE.com", "https://example.com/emby/", "https://example.com:443/emby", "https://backup.example.com"]).count == 2)
        checkVersionMatching()
        checkPlaybackCacheSizing()
        try checkSkipMarkers()
        UserDefaults.standard.set(true, forKey: EmbyUserAgentPolicy.enabledKey)
        UserDefaults.standard.set("CustomVesper", forKey: EmbyUserAgentPolicy.nameKey)
        UserDefaults.standard.set("2.0", forKey: EmbyUserAgentPolicy.versionKey)
        let configuration = EmbySourceConfiguration(title: "家庭影院", note: "媒体服务器", serverAddress: CommandLine.arguments[1] + "/proxy",
                                                     username: "test", serverID: "server", userID: "user",
                                                     customHeaders: [:])
        let client = try EmbyAPIClient(configuration: configuration, token: "secret", deviceID: "stable-device")
        let repository = EmbyRepository(clientProvider: { _ in client })
        let source = MediaSource(id: UUID(), name: configuration.title, kind: .emby, behavior: .empty, emby: configuration)
        let blankSearch = try await repository.search(for: source, query: "  ")
        precondition(blankSearch.items.isEmpty && !blankSearch.hasMore)
        let firstSearch = try await repository.search(for: source, query: "  晚风 & café /?  ", limit: 2)
        precondition(firstSearch.items.map(\.id.localID) == ["movie"])
        precondition(firstSearch.nextIndex == 2 && firstSearch.hasMore) // Count raw rows, including discarded types.
        let lastSearch = try await repository.search(for: source, query: "晚风 & café /?", startIndex: firstSearch.nextIndex, limit: 2)
        precondition(lastSearch.items.map(\.id.localID) == ["series"])
        precondition(lastSearch.nextIndex == 3 && !lastSearch.hasMore)
        do {
            _ = try await repository.search(for: source, query: "invalid-response")
            preconditionFailure("A malformed search response must not look like no results")
        } catch EmbyError.invalidResponse { }

        for type in ["Movie", "Series", "Episode"] {
            let target = MediaItem(id: MediaID(sourceID: source.id, localID: "action-" + type),
                                   title: type, resource: nil, embyItemType: type)
            try await repository.setPlayed(true, for: target, source: source)
            try await repository.setPlayed(false, for: target, source: source)
            try await repository.setFavorite(true, for: target, source: source)
            try await repository.setFavorite(false, for: target, source: source)
            try await repository.setProgress(12.5, for: target, source: source)
            try await repository.clearProgress(for: target, source: source)
        }
        let roots = try await repository.rootItems(for: source)
        precondition(roots.count == 3 && roots[0].isContainer)
        let libraries = try await repository.mediaLibraries(for: source)
        precondition(libraries.map(\.id.localID) == ["library", "sets", "lists"] && libraries.allSatisfy(\.isContainer))
        let libraryThumbnail = await repository.thumbnailData(for: libraries[0], source: source, orientation: .landscape)
        let libraryImage = try JSONDecoder().decode([String: String].self, from: libraryThumbnail ?? Data())
        precondition(libraryImage["image"] == "library-default-primary")
        let favorites = try await repository.items(for: source, parentID: nil, startIndex: 21,
                                                   limit: 21, scope: .favorites)
        precondition(favorites.map(\.id.localID) == ["movie", "series", "episode"])
        let latest = try await repository.latestMedia(for: source, libraryID: libraries[0].id.localID)
        precondition(latest.count == 20 && latest.first?.id.localID == "movie-0")
        precondition(latest.allSatisfy { $0.dateCreated != nil })
        precondition(latest.last?.isEmbySeries == true && latest.last?.isContainer == true)
        let featuredMedia = try await repository.featuredMedia(for: source)
        precondition(featuredMedia.count == 10 && featuredMedia.first?.id.localID == "featured-0")
        precondition(featuredMedia.last?.isEmbySeries == true)
        let series = featuredMedia.last!
        precondition(series.embyPresentation?.genres == ["Drama", "Mystery"])
        precondition(series.embyPresentation?.status == "Continuing" && series.embyPresentation?.rating == "TV-14")
        precondition(series.embyPresentation?.seasonCount == 2 && series.embyPresentation?.communityRating == 8.4)
        precondition(series.embyPresentation?.premiereDate?.timeIntervalSince1970 == 1_709_251_200)
        let posterCandidates = await repository.featuredPosterCandidates(for: series, source: source)
        precondition(posterCandidates.map(\.lastPathComponent) == ["titled.jpg", "textless.jpg"])
        let logo = await repository.artworkData(for: series, source: source, purpose: .logo)
        let logoImage = try JSONDecoder().decode([String: String].self, from: logo ?? Data())
        precondition(logoImage["image"] == "default-logo")
        let noLogoItem = MediaItem(id: MediaID(sourceID: source.id, localID: "no-logo"),
                                   title: "No Logo", resource: nil, embyItemID: "no-logo", embyItemType: "Series")
        let missingLogo = await repository.artworkData(for: noLogoItem, source: source, purpose: .logo)
        precondition(missingLogo == nil)
        let metadata = try await repository.detailMetadata(for: series, source: source)
        precondition(metadata.item.embyPresentation?.overview == "Series synopsis")
        let seriesFields = Dictionary(uniqueKeysWithValues: metadata.seriesInformation.flatMap(\.fields).map { ($0.id, $0.value) })
        precondition(seriesFields["OriginalTitle"] == "Original Series")
        precondition(seriesFields["AirDays"] == "周一" && seriesFields["SeasonCount"] == "2")
        precondition(seriesFields["Studios"] == "Example Network")
        precondition(Set(["SortName", "RunTimeTicks", "ChildCount", "RecursiveItemCount", "Id", "Type",
                         "Path", "PremiereDate", "DateCreated", "LockData", "ProviderIds", "Played"])
            .isDisjoint(with: seriesFields.keys))
        precondition(metadata.credits.first?.role == "Detective" && metadata.credits.first?.image?.id.localID == "actor")
        let actor = metadata.credits[0].person
        let director = metadata.credits[1].person
        precondition(actor.id == "actor" && director.id == nil && metadata.credits[1].image == nil)
        let actorScope = EmbyBrowseScope.person(actor)
        let directorScope = EmbyBrowseScope.person(director)
        precondition(actorScope.cacheKey != directorScope.cacheKey && actorScope.cacheKey != EmbyBrowseScope.favorites.cacheKey)
        let actorWorks = try await repository.items(for: source, parentID: nil, startIndex: 21, limit: 21,
                                                    sortBy: "DateCreated", sortOrder: "Descending", scope: actorScope)
        precondition(actorWorks.map(\.id.localID) == ["movie", "series"])
        let directorWorks = try await repository.items(for: source, parentID: nil, startIndex: 0, limit: 21,
                                                       sortBy: "DateCreated", sortOrder: "Descending", scope: directorScope)
        precondition(directorWorks.map(\.id.localID) == ["series"])
        precondition(Set(metadata.links.map(\.name)) == ["IMDb", "豆瓣"])
        let seriesEpisodes = try await repository.seriesEpisodes(for: series, source: source)
        precondition(seriesEpisodes.map(\.season) == [1, 2] && seriesEpisodes.map(\.played) == [false, true])
        let episode = seriesEpisodes[0]
        precondition(episode.number == 2 && episode.item.resumePosition == 30)
        precondition(episode.item.embyPresentation?.overview == "Episode synopsis")
        precondition(episode.is4K && episode.dolbyVision && episode.dolbyAtmos)
        let episodeThumbnail = await repository.artworkData(for: episode.item, source: source, purpose: .thumbnail, orientation: .landscape)
        let episodeImage = try JSONDecoder().decode([String: String].self, from: episodeThumbnail ?? Data())
        precondition(episodeImage["image"] == "episode-thumb")
        let unnamedEpisode = seriesEpisodes[1].item
        precondition(unnamedEpisode.title.isEmpty && unnamedEpisode.isPlayed == true)
        let missingEpisodeThumbnail = await repository.thumbnailData(for: unnamedEpisode, source: source,
                                                                      orientation: .landscape)
        precondition(missingEpisodeThumbnail == nil)
        let similar = try await repository.similarTitles(for: series, source: source)
        precondition(similar.map(\.id.localID) == ["movie"])
        try await repository.updatePlaybackRecord(for: episode.item, source: source, change: .setPlayed(true))
        try await repository.updatePlaybackRecord(for: episode.item, source: source, change: .setPlayed(false))
        try await repository.updatePlaybackRecord(for: episode.item, source: source, change: .clearProgress)
        let featured = EmbyMediaGroup.featured(in: [
            .init(id: EmbyMediaGroup.librariesID, title: "Libraries", items: libraries),
            .init(id: "first", title: "First", items: Array(latest.dropFirst())),
            .init(id: "second", title: "Second", items: Array(latest.prefix(2)))
        ])
        let featuredCandidates = Set(latest.map(\.id))
        precondition(featured.count == 10 && Set(featured.map(\.id)).count == 10)
        precondition(featured.allSatisfy { featuredCandidates.contains($0.id) })
        let cachedItems = try JSONDecoder().decode([MediaItem].self, from: JSONEncoder().encode(latest))
        precondition(cachedItems == latest)
        let titles = try await repository.items(for: source, parentID: "library", startIndex: 21,
                                                limit: 21, scope: .titles)
        precondition(titles.map(\.id.localID) == ["movie", "series"] && titles.last?.isEmbySeries == true)
        let episodes = try await repository.items(for: source, parentID: "series", startIndex: 0,
                                                  limit: 21, scope: .episodes)
        precondition(episodes.map(\.embyItemType) == ["Episode"])
        let items = try await repository.items(for: source, parentID: "library", startIndex: 100)
        precondition(items.count == 1 && !items[0].isContainer)
        var item = items[0]
        precondition(item.fallbackImageURL?.path == "/proxy/emby/Items/series/Images/Primary")
        let thumbnail = await repository.thumbnailData(for: item, source: source, orientation: .landscape)
        let movieImage = try JSONDecoder().decode([String: String].self, from: thumbnail ?? Data())
        precondition(movieImage["image"] == "movie-default-primary")
        precondition(thumbnail != nil)
        let portraitThumbnail = await repository.artworkData(for: item, source: source, purpose: .poster, orientation: .portrait)
        let portraitImage = try JSONDecoder().decode([String: String].self, from: portraitThumbnail ?? Data())
        precondition(portraitImage["image"] == "movie-default-primary")
        let ratioNeutralItem = MediaItem(id: MediaID(sourceID: source.id, localID: "ratio-neutral"),
                                         title: "Neutral Ratio", resource: nil,
                                         embyItemType: "Movie")
        let ratioNeutralThumbnail = await repository.thumbnailData(for: ratioNeutralItem, source: source, orientation: .square)
        let ratioNeutralImage = try JSONDecoder().decode([String: String].self, from: ratioNeutralThumbnail ?? Data())
        precondition(ratioNeutralImage["image"] == "ratio-neutral-portrait")
        precondition(item.id.sourceID == source.id && item.id.localID == "movie")
        precondition(item.resumePosition == 30 && item.duration == 600)
        let details = try await repository.details(for: item, source: source)
        precondition(details.versions.count == 2 && details.video.synopsis == "A movie")
        let selectedVersion = details.mediaVersions.first { $0.id == "v2" }!
        precondition(selectedVersion.fileName == "movie-v2.mkv" && selectedVersion.container == "mkv")
        precondition(selectedVersion.size == 7_340_032_000 && selectedVersion.supportsDirectPlay == true)
        let audio = selectedVersion.streams.first { $0.type == "Audio" }!
        precondition(audio.codec == "eac3" && audio.channels == 6 && audio.sampleRate == 48_000 && audio.isDefault)
        let subtitle = selectedVersion.streams.first { $0.type == "Subtitle" }!
        precondition(subtitle.isHearingImpaired && subtitle.isExternal && subtitle.deliveryMethod == "External")
        item.embyMediaSourceID = "v2"
        let resource = try await repository.playbackResource(item: item, source: source, position: 30)
        precondition(resource.mediaSourceID == "v2" && resource.resumePosition == 30)
        precondition(resource.bitRate == 48_000_000)
        precondition(resource.subtitles.count == 1 && resource.subtitles[0].url.path.contains("/v2/Subtitles/2/"))
        precondition(resource.resource.headers["User-Agent"] == "CustomVesper/2.0")
        precondition(resource.resource.headers["Authorization"] == nil)
        precondition(resource.resource.headers["X-Emby-Token"] == nil)
        precondition(URLComponents(url: resource.resource.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "api_key", value: "secret")) == true)
        precondition(URLComponents(url: resource.subtitles[0].url, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "api_key", value: "secret")) == true)
        precondition(resource.resource.url.absoluteString.contains("MediaSourceId=v2"))
        let stream = try await repository.transcodedResource(item: item, source: source, position: 200)
        precondition(stream.resource.timelineOffset == 200 && stream.resource.originalDuration == 600)
        precondition(stream.resource.bitRate == 12_000_000)
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
    private static func checkVersionMatching() {
        typealias Format = EmbyVersionMatcher.Format
        let current = Format(container: "mkv", videoCodec: "hevc", dynamicRange: "DV",
                             width: 3840, height: 2160, audioCodec: "eac3", audioChannels: 6, bitRate: 20_000_000)
        let lower = Format(container: "mkv", videoCodec: "hevc", dynamicRange: "DV", width: 1920, height: 1080)
        let hdr = Format(container: "mkv", videoCodec: "hevc", dynamicRange: "HDR10", width: 3840, height: 2160)
        let matching = Format(container: "matroska", videoCodec: "h265", dynamicRange: "DV",
                              width: 3840, height: 2160, audioCodec: "ec-3", audioChannels: 6, bitRate: 19_000_000)
        precondition(EmbyVersionMatcher.bestIndex(current: current, candidates: [hdr, lower, matching]) == 2)
        precondition(EmbyVersionMatcher.bestIndex(current: current, candidates: [hdr, lower]) == 1)
        precondition(EmbyVersionMatcher.bestIndex(current: current, candidates: []) == nil)
        precondition(EmbyVersionMatcher.bestIndex(current: Format(), candidates: [hdr, matching]) == 0)
        precondition(EmbyVersionMatcher.bestIndex(current: current, candidates: [matching, matching]) == 0)
    }

    private static func checkPlaybackCacheSizing() {
        // Decimal MB and bits/s: 100 MB at 20 Mbps represents 40 seconds.
        precondition(PlaybackCacheSizing.vlcMilliseconds(byteLimit: 100_000_000, bitRate: 20_000_000) == 40_000)
        precondition(PlaybackCacheSizing.vlcMilliseconds(byteLimit: 500_000_000, bitRate: 100_000_000) == 40_000)
        precondition(PlaybackCacheSizing.vlcMilliseconds(byteLimit: 500_000_000, bitRate: 20_000_000) == 60_000)
        for rate in [nil, Double(0), -1, .nan, .infinity] as [Double?] {
            precondition(PlaybackCacheSizing.vlcMilliseconds(byteLimit: 100_000_000, bitRate: rate) == 40_000)
        }
        precondition(PlaybackCacheSizing.vlcMilliseconds(byteLimit: Int.max, bitRate: .leastNonzeroMagnitude) == 60_000)
        precondition(PlaybackCacheSizing.vlcMilliseconds(byteLimit: -1, bitRate: 20_000_000) == 1)
        precondition(EmbyRepository.playbackBitRate(["Bitrate": 40_000_000, "Size": 1, "RunTimeTicks": 10_000_000]) == 40_000_000)
        precondition(EmbyRepository.playbackBitRate(["Bitrate": 0, "Size": 500_000_000, "RunTimeTicks": 2_000_000_000]) == 20_000_000)
        precondition(EmbyRepository.playbackBitRate(["MediaStreams": [
            ["Type": "Video", "BitRate": 20_000_000], ["Type": "Audio", "BitRate": 768_000],
            ["Type": "Subtitle", "BitRate": 1_000]
        ]]) == 20_768_000)
        precondition(EmbyRepository.playbackBitRate([:]) == nil)
    }

    private static func checkSkipMarkers() throws {
        let intro = Data(#"{"intro":{"start_ms":10000,"end_ms":70000},"outro":{"start_ms":550000,"end_ms":600000}}"#.utf8)
        let value = try EmbySkipMarkers.decode(intro, format: .introDB, duration: 600)
        precondition(value.intros == [.init(start: 10, end: 70)] && value.creditsStart == 550)
        precondition(value.preloadPosition(duration: 600, fraction: 0.8, introEnabled: true, outroEnabled: true) == 452)
        precondition(value.preloadPosition(duration: 600, fraction: 0.8, introEnabled: false, outroEnabled: false) == 480)
        let v4 = Data(#"{"intro":[{"start_ms":null,"end_ms":30000},{"start_ms":20000,"end_ms":40000}],"credits":[{"start_ms":500000,"end_ms":null}]}"#.utf8)
        let merged = try EmbySkipMarkers.decode(v4, format: .theIntroDB, duration: 600)
        precondition(merged.intros == [.init(start: 0, end: 40)] && merged.creditsStart == 500)
        let invalid = Data(#"{"intro":{"start_ms":80000,"end_ms":10000},"outro":{"start_ms":900000}}"#.utf8)
        let rejected = try EmbySkipMarkers.decode(invalid, format: .introDB, duration: 600)
        precondition(!rejected.hasData)
        precondition(EmbySkipDatabase.builtins.count == 2 && EmbySkipDatabase.builtins.allSatisfy(\.isBuiltin))
    }

}
