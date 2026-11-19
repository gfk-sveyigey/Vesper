import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PlaybackContracts

struct EmbyAuthentication: Sendable {
    let serverID: String
    let userID: String?
    let serverName: String?
}

struct EmbyPlaybackResource: Sendable {
    let resource: PlayableResource
    let sessionID: String
    let mediaSourceID: String
    let duration: Double
    let resumePosition: Double
    let subtitles: [EngineExternalSubtitle]
}

struct EmbyTranscodeResult: Sendable {
    let resource: TranscodedPlaybackResource
    let sessionID: String
}

struct EmbyItemDetails: Sendable {
    let video: PlaybackVideoDetails
    let versions: [MediaItem]
}

enum EmbyBrowsingSettings {
    static let fullRenderingKey = "emby.fullRendering"
}

struct EmbyMediaGroup: Identifiable, Sendable {
    static let librariesID = "all-media"
    let id: String
    let title: String
    var items: [MediaItem]
    var isLoading = false
    var errorMessage: String? = nil

    static func featured(in groups: [Self]) -> [MediaItem] {
        let sorted = groups.filter { $0.id != librariesID }.flatMap(\.items).sorted {
            let left = $0.dateCreated ?? .distantPast
            let right = $1.dateCreated ?? .distantPast
            return left == right ? $0.id.localID < $1.id.localID : left > right
        }
        var seen = Set<MediaID>()
        return Array(sorted.filter { seen.insert($0.id).inserted }.prefix(10))
    }
}

struct EmbyEpisode: Identifiable, Sendable {
    var item: MediaItem
    let season: Int
    let number: Int?
    var played: Bool
    let is4K: Bool
    let dolbyVision: Bool
    let dolbyAtmos: Bool
    var id: MediaID { item.id }
}

struct EmbyCredit: Identifiable, Sendable {
    let id: String
    let name: String
    let role: String
    let image: MediaItem?
}

struct EmbyExternalLink: Identifiable, Sendable {
    let name: String
    let url: URL
    var id: URL { url }
}

struct EmbySeriesMetadata: Sendable {
    let item: MediaItem
    let credits: [EmbyCredit]
    let links: [EmbyExternalLink]
}

enum EmbyBrowseScope: String, Sendable {
    case children, titles, episodes, favorites

    var itemTypes: [String]? {
        switch self {
        case .children: nil
        case .titles: ["Movie", "Series", "Video", "MusicVideo", "Trailer"]
        case .favorites: ["Movie", "Series", "Episode", "Video", "MusicVideo", "Trailer"]
        case .episodes: ["Episode"]
        }
    }
}

actor EmbyRepository {
    static let shared = EmbyRepository()
    private let clientProvider: @MainActor @Sendable (MediaSource) throws -> EmbyAPIClient

    init(clientProvider: @escaping @MainActor @Sendable (MediaSource) throws -> EmbyAPIClient = {
        try EmbyAccountStore.shared.client(for: $0)
    }) {
        self.clientProvider = clientProvider
    }

    func rootItems(for source: MediaSource) async throws -> [MediaItem] {
        let client = try await clientProvider(source)
        let response: EmbyJSON
        if let userID = source.emby?.userID {
            response = try await client.get("Users/\(userID)/Views")
        } else {
            response = try await client.get("Items", query: ["Recursive": "true", "IncludeItemTypes": "Movie,Series,Episode,Folder", "Limit": "100", "SortBy": "SortName"])
        }
        return map(response["Items"] as? [[String: Any]] ?? [], source: source, client: client)
    }

    func mediaLibraries(for source: MediaSource) async throws -> [MediaItem] {
        let client = try await clientProvider(source)
        let response: EmbyJSON
        if let userID = source.emby?.userID {
            response = try await client.get("Users/\(userID)/Views")
        } else {
            response = try await client.get("Items", query: ["Recursive": "false", "IncludeItemTypes": "CollectionFolder,Folder"])
        }
        guard let values = response["Items"] as? [[String: Any]] else { throw EmbyError.invalidResponse }
        var seen = Set<MediaID>()
        let libraries = values.filter { value in
            let collectionType = (value["CollectionType"] as? String)?.lowercased()
            let itemType = (value["Type"] as? String)?.lowercased()
            return !["boxset", "boxsets", "collection", "collections", "playlist", "playlists"].contains(collectionType ?? "")
                && !["boxset", "playlist"].contains(itemType ?? "")
        }
        return map(libraries, source: source, client: client).filter { $0.isContainer && seen.insert($0.id).inserted }
    }

    func latestMedia(for source: MediaSource, libraryID: String) async throws -> [MediaItem] {
        try await latestMedia(for: source, parentID: libraryID, limit: 20)
    }

    func featuredMedia(for source: MediaSource) async throws -> [MediaItem] {
        try await latestMedia(for: source, parentID: nil, limit: 10)
    }

    private func latestMedia(for source: MediaSource, parentID: String?, limit: Int) async throws -> [MediaItem] {
        let client = try await clientProvider(source)
        let path = source.emby?.userID.map { "Users/\($0)/Items" } ?? "Items"
        let titleTypes = EmbyBrowseScope.titles.itemTypes ?? []
        var query = [
            "Recursive": "true",
            "IncludeItemTypes": titleTypes.joined(separator: ","),
            "SortBy": "DateCreated", "SortOrder": "Descending", "StartIndex": "0", "Limit": String(limit),
            "EnableImages": "true",
            "Fields": "DateCreated,ProductionYear,RunTimeTicks,UserData,Genres,PremiereDate,Status,OfficialRating"
        ]
        if let parentID { query["ParentId"] = parentID }
        let response = try await client.get(path, query: query)
        guard let values = response["Items"] as? [[String: Any]] else { throw EmbyError.invalidResponse }
        var seen = Set<MediaID>()
        return Array(map(values, source: source, client: client)
            .filter { titleTypes.contains($0.embyItemType ?? "") && seen.insert($0.id).inserted }.prefix(limit))
    }

    func serverName(for source: MediaSource) async throws -> String? {
        let client = try await clientProvider(source)
        let info = try await client.get("System/Info/Public")
        let serverName = (info["ServerName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let productName = (info["ProductName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return serverName?.isEmpty == false ? serverName : productName
    }

    func alternateAddresses(for source: MediaSource) async throws -> [String] {
        let client = try await clientProvider(source)
        let info = try await client.get("System/Info")
        let values = (info["AlternateUrls"] as? [String] ?? [])
            + ["LocalAddress", "WanAddress", "ServerAddress"].compactMap { info[$0] as? String }
        return Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != source.emby?.serverAddress })).sorted()
    }

    func items(for source: MediaSource, parentID: String?, startIndex: Int,
               limit: Int = 100, sortBy: String = "SortName", sortOrder: String = "Ascending",
               scope: EmbyBrowseScope = .children) async throws -> [MediaItem] {
        let client = try await clientProvider(source)
        var query = ["StartIndex": String(startIndex), "Limit": String(limit), "Fields": "Overview,PrimaryImageAspectRatio,MediaSources,DateCreated,ProductionYear,RunTimeTicks,UserData,Genres,PremiereDate",
                     "SortBy": sortBy, "SortOrder": sortOrder]
        if let parentID { query["ParentId"] = parentID }
        else if source.emby?.userID != nil && scope != .favorites { query["ParentId"] = "" }
        if scope == .favorites { query["Filters"] = "IsFavorite" }
        if let itemTypes = scope.itemTypes {
            query["Recursive"] = "true"
            query["IncludeItemTypes"] = itemTypes.joined(separator: ",")
        }
        let path = source.emby?.userID.map { "Users/\($0)/Items" } ?? "Items"
        let response = try await client.get(path, query: query)
        guard let values = response["Items"] as? [[String: Any]] else { throw EmbyError.invalidResponse }
        let items = map(values, source: source, client: client)
        guard let itemTypes = scope.itemTypes else { return items }
        return items.filter { itemTypes.contains($0.embyItemType ?? "") }
    }

    func seriesMetadata(for item: MediaItem, source: MediaSource) async throws -> EmbySeriesMetadata {
        let client = try await clientProvider(source)
        let path = source.emby?.userID.map { "Users/\($0)/Items/\(item.id.localID)" } ?? "Items/\(item.id.localID)"
        let response = try await client.get(path)
        let credits = (response["People"] as? [[String: Any]] ?? []).enumerated().compactMap { index, value -> EmbyCredit? in
            guard let name = value["Name"] as? String else { return nil }
            let image = (value["Id"] as? String).map { id in
                MediaItem(id: MediaID(sourceID: source.id, localID: id), title: name, resource: nil,
                          imageURL: client.imageURL(itemID: id, tag: value["PrimaryImageTag"] as? String, width: 200))
            }
            let role = (value["Role"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value["Type"] as? String ?? ""
            return EmbyCredit(id: "\(index)", name: name, role: role, image: image)
        }
        let providers = response["ProviderIds"] as? [String: String] ?? [:]
        let traktID = providers.first(where: { $0.key.caseInsensitiveCompare("Trakt") == .orderedSame })?.value
        var links = (response["ExternalUrls"] as? [[String: Any]] ?? []).compactMap { value -> EmbyExternalLink? in
            guard let name = value["Name"] as? String, let raw = value["Url"] as? String,
                  !(name.localizedCaseInsensitiveContains("trakt") && traktID != nil),
                  let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { return nil }
            return EmbyExternalLink(name: name, url: url)
        }
        if let traktID, traktID.utf8.allSatisfy({ (48...57).contains($0) }),
           let url = URL(string: "https://trakt.tv/\(item.isEmbySeries ? "shows" : "movies")/\(traktID)") {
            links.append(EmbyExternalLink(name: "Trakt", url: url))
        }
        for (provider, name, base) in [("Imdb", "IMDb", "https://www.imdb.com/title/"),
                                       ("Tmdb", "TMDb", "https://www.themoviedb.org/tv/"),
                                       ("Douban", "豆瓣", "https://movie.douban.com/subject/")] {
            guard let id = providers.first(where: { $0.key.caseInsensitiveCompare(provider) == .orderedSame })?.value,
                  !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }),
                  !links.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  let url = URL(string: base + id) else { continue }
            links.append(EmbyExternalLink(name: name, url: url))
        }
        var seen = Set<URL>()
        return EmbySeriesMetadata(item: map([response.values], source: source, client: client).first ?? item,
                                  credits: credits, links: links.filter { seen.insert($0.url).inserted })
    }

    func seriesEpisodes(for series: MediaItem, source: MediaSource) async throws -> [EmbyEpisode] {
        let client = try await clientProvider(source)
        var query = ["Fields": "Overview,MediaStreams,MediaSources,RunTimeTicks", "Limit": "100",
                     "EnableUserData": "true", "EnableTotalRecordCount": "true"]
        if let userID = source.emby?.userID { query["UserId"] = userID }
        var episodes: [EmbyEpisode] = []
        var seen = Set<MediaID>()
        var offset = 0
        while true {
            try Task.checkCancellation()
            query["StartIndex"] = String(offset)
            let response = try await client.get("Shows/\(series.id.localID)/Episodes", query: query)
            guard let rows = response["Items"] as? [[String: Any]] else { throw EmbyError.invalidResponse }
            if rows.isEmpty { break }
            var madeProgress = false
            for row in rows {
                guard let item = map([row], source: source, client: client).first,
                      item.embyItemType == "Episode", seen.insert(item.id).inserted else { continue }
                madeProgress = true
                let media = row["MediaSources"] as? [[String: Any]] ?? []
                let streams = (row["MediaStreams"] as? [[String: Any]] ?? []) +
                    media.flatMap { $0["MediaStreams"] as? [[String: Any]] ?? [] }
                let video = streams.filter { $0["Type"] as? String == "Video" }
                let dolbyVision = video.contains {
                    let range = ($0["VideoRangeType"] as? String ?? "").uppercased()
                    return range.hasPrefix("DOVI") || range.hasPrefix("DV") || range.contains("DOLBY VISION")
                        || ($0["DvProfile"] as? Int ?? 0) > 0
                }
                let dolbyAtmos = streams.contains { stream in
                    stream["Type"] as? String == "Audio" &&
                        ["Profile", "DisplayTitle"].contains { key in
                            (stream[key] as? String ?? "").localizedCaseInsensitiveContains("Atmos")
                        }
                }
                episodes.append(EmbyEpisode(item: item, season: row["ParentIndexNumber"] as? Int ?? 0,
                                            number: row["IndexNumber"] as? Int,
                                            played: (row["UserData"] as? [String: Any])?["Played"] as? Bool ?? false,
                                            is4K: video.contains { ($0["Width"] as? Int ?? 0) >= 3800 },
                                            dolbyVision: dolbyVision, dolbyAtmos: dolbyAtmos))
            }
            offset += rows.count
            if !madeProgress { break }
            if let total = response["TotalRecordCount"] as? Int {
                if offset >= total { break }
            } else if rows.count < 100 {
                break
            }
        }
        return episodes.sorted {
            ($0.season, $0.number ?? Int.max, $0.id.localID) < ($1.season, $1.number ?? Int.max, $1.id.localID)
        }
    }

    func similarTitles(for item: MediaItem, source: MediaSource) async throws -> [MediaItem] {
        let client = try await clientProvider(source)
        var query = ["Limit": "20", "Fields": "Genres,PremiereDate,Overview"]
        if let userID = source.emby?.userID { query["UserId"] = userID }
        let response = try await client.get("Items/\(item.id.localID)/Similar", query: query)
        let rows = response["Items"] as? [[String: Any]] ?? []
        var seen: Set<MediaID> = [item.id]
        return map(rows, source: source, client: client).filter {
            ($0.isEmbySeries || $0.embyItemType == "Movie") && seen.insert($0.id).inserted
        }
    }

    func updateEpisode(_ episode: EmbyEpisode, source: MediaSource, markPlayed: Bool) async throws {
        try await updateWatchState(for: episode.item, source: source, markPlayed: markPlayed)
    }

    func updateWatchState(for item: MediaItem, source: MediaSource, markPlayed: Bool) async throws {
        guard let userID = source.emby?.userID else { throw EmbyError.missingAccount }
        let client = try await clientProvider(source)
        if markPlayed {
            _ = try await client.send("Users/\(userID)/PlayedItems/\(item.id.localID)", method: "POST")
        } else {
            let path = "Users/\(userID)/Items/\(item.id.localID)/UserData"
            let stored = try await client.get("Users/\(userID)/Items/\(item.id.localID)")
            guard var data = stored["UserData"] as? [String: Any] else { throw EmbyError.invalidResponse }
            data["PlaybackPositionTicks"] = 0
            _ = try await client.send(path, method: "POST", body: EmbyJSON(data))
        }
    }

    func details(for item: MediaItem, source: MediaSource) async throws -> EmbyItemDetails {
        let client = try await clientProvider(source)
        let path = source.emby?.userID.map { "Users/\($0)/Items/\(item.id.localID)" } ?? "Items/\(item.id.localID)"
        let response = try await client.get(path)
        let sources = response["MediaSources"] as? [[String: Any]] ?? []
        let media = sources.first(where: { $0["Id"] as? String == item.embyMediaSourceID }) ?? sources.first ?? [:]
        var fields: [PlaybackDetailField] = []
        if let container = media["Container"] as? String { fields.append(.init(label: "容器格式", value: container)) }
        if let bitrate = media["Bitrate"] as? NSNumber {
            fields.append(.init(label: "总码率", value: String(format: "%.2f Mbit/s", bitrate.doubleValue / 1_000_000)))
        }
        let streams = media["MediaStreams"] as? [[String: Any]] ?? []
        var dimensions: String?
        for stream in streams {
            let type = stream["Type"] as? String ?? ""
            guard ["Video", "Audio", "Subtitle"].contains(type) else { continue }
            let prefix = type == "Video" ? "视频" : type == "Audio" ? "音频" : "字幕"
            if let codec = stream["Codec"] as? String { fields.append(.init(label: prefix + "编码", value: codec)) }
            if let language = stream["Language"] as? String { fields.append(.init(label: prefix + "语言", value: language)) }
            if let bitrate = stream["BitRate"] as? NSNumber {
                fields.append(.init(label: prefix + "码率", value: String(format: "%.1f kbit/s", bitrate.doubleValue / 1000)))
            }
            for (key, label) in [("VideoRange", "动态范围"), ("ColorPrimaries", "色彩原色"),
                                 ("ColorTransfer", "传递函数"), ("ColorSpace", "色彩空间"),
                                 ("AspectRatio", "画面比例"), ("ChannelLayout", "声道布局"),
                                 ("SampleRate", "采样率"), ("RealFrameRate", "帧率")] {
                if let value = stream[key] { fields.append(.init(label: label, value: String(describing: value))) }
            }
            if type == "Video", let width = stream["Width"] as? Int, let height = stream["Height"] as? Int {
                dimensions = "\(width) × \(height)"
            }
        }
        let versions = sources.compactMap { version -> MediaItem? in
            guard let id = version["Id"] as? String else { return nil }
            var result = item
            result.embyMediaSourceID = id
            result.subtitle = version["Name"] as? String ?? id
            result.duration = (version["RunTimeTicks"] as? NSNumber).map { $0.doubleValue / 10_000_000 }
            return result
        }
        let video = PlaybackVideoDetails(fileName: item.title, dimensions: dimensions,
                                         byteCount: media["Size"] as? Int, synopsis: response["Overview"] as? String,
                                         sourceName: source.name, technical: fields)
        return EmbyItemDetails(video: video, versions: versions)
    }

    func playbackResource(item: MediaItem, source: MediaSource, position: Double) async throws -> EmbyPlaybackResource {
        guard let itemID = item.embyItemID else { throw EmbyError.invalidResponse }
        let client = try await clientProvider(source)
        var payload: [String: Any] = ["MaxStreamingBitrate": 120_000_000,
                                      "StartTimeTicks": Int64(max(0, position) * 10_000_000),
                                      "EnableDirectPlay": true, "EnableDirectStream": true, "EnableTranscoding": true,
                                      "DeviceProfile": Self.deviceProfile]
        if let userID = source.emby?.userID { payload["UserId"] = userID }
        if let mediaSourceID = item.embyMediaSourceID { payload["MediaSourceId"] = mediaSourceID }
        let response = try await client.send("Items/\(itemID)/PlaybackInfo", method: "POST", body: EmbyJSON(payload))
        guard let playSessionID = response["PlaySessionId"] as? String else { throw EmbyError.invalidResponse }
        guard let sources = response["MediaSources"] as? [[String: Any]],
              let media = sources.first(where: { $0["Id"] as? String == item.embyMediaSourceID }) ?? sources.first,
              let mediaSourceID = media["Id"] as? String else { throw EmbyError.invalidResponse }
        let addApiKey = media["AddApiKeyToDirectStreamUrl"] as? Bool ?? false
        let directURL = media["DirectStreamUrl"] as? String
        let url: URL
        if let directURL { url = try client.resolveMediaURL(directURL, includeToken: addApiKey) }
        else {
            url = try client.mediaURL("Videos/\(itemID)/stream", query: ["static": "true", "MediaSourceId": mediaSourceID,
                                                                           "PlaySessionId": playSessionID, "DeviceId": client.deviceID],
                                      includeToken: addApiKey)
        }
        var headers = client.requestHeaders(accept: "*/*", kind: .playback)
        if let required = media["RequiredHttpHeaders"] as? [String: String] {
            for (name, value) in required where !["authorization", "x-emby-token", "x-emby-authorization", "host", "user-agent"].contains(name.lowercased()) {
                headers[name] = value
            }
        }
        let duration = (media["RunTimeTicks"] as? NSNumber).map { $0.doubleValue / 10_000_000 } ?? 0
        let progressTicks: NSNumber?
        if let userID = source.emby?.userID {
            let detail = try await client.get("Users/\(userID)/Items/\(itemID)")
            progressTicks = (detail["UserData"] as? [String: Any])?["PlaybackPositionTicks"] as? NSNumber
        } else {
            progressTicks = nil
        }
        let subtitles = externalSubtitles(media: media, itemID: itemID, client: client)
        return EmbyPlaybackResource(resource: PlayableResource(url: url, headers: headers), sessionID: playSessionID,
                                    mediaSourceID: mediaSourceID, duration: duration,
                                    resumePosition: (progressTicks?.doubleValue ?? 0) / 10_000_000, subtitles: subtitles)
    }

    func transcodedResource(item: MediaItem, source: MediaSource, position: Double,
                            forceVideoTranscode: Bool = false) async throws -> EmbyTranscodeResult {
        guard let itemID = item.embyItemID, let userID = source.emby?.userID else { throw EmbyError.invalidResponse }
        let client = try await clientProvider(source)
        var payload: [String: Any] = ["UserId": userID, "StartTimeTicks": Int64(max(0, position) * 10_000_000),
                                "MaxStreamingBitrate": 120_000_000,
                                "EnableDirectPlay": false, "EnableDirectStream": false, "EnableTranscoding": true,
                                "AllowVideoStreamCopy": !forceVideoTranscode, "AllowAudioStreamCopy": !forceVideoTranscode,
                                "DeviceProfile": Self.deviceProfile]
        if let id = item.embyMediaSourceID { payload["MediaSourceId"] = id }
        let response = try await client.send("Items/\(itemID)/PlaybackInfo", method: "POST", body: EmbyJSON(payload))
        guard let sessionID = response["PlaySessionId"] as? String,
              let mediaSources = response["MediaSources"] as? [[String: Any]],
              let media = mediaSources.first(where: { $0["Id"] as? String == item.embyMediaSourceID }) ?? mediaSources.first,
              let stream = media["TranscodingUrl"] as? String,
              let url = try? client.resolveMediaURL(stream, includeToken: media["AddApiKeyToDirectStreamUrl"] as? Bool ?? false) else { throw EmbyError.invalidResponse }
        var headers = client.requestHeaders(accept: "*/*", kind: .playback)
        if let required = media["RequiredHttpHeaders"] as? [String: String] {
            for (name, value) in required where !["authorization", "x-emby-token", "x-emby-authorization", "host", "user-agent"].contains(name.lowercased()) {
                headers[name] = value
            }
        }
        let ticks = (media["RunTimeTicks"] as? NSNumber)?.doubleValue ?? ((item.duration ?? 0) * 10_000_000)
        return EmbyTranscodeResult(resource: TranscodedPlaybackResource(url: url, headers: headers,
                                                                          timelineOffset: position,
                                                                          originalDuration: ticks / 10_000_000),
                                   sessionID: sessionID)
    }

    func report(source: MediaSource, itemID: String, playSessionID: String, position: Double,
                mediaSourceID: String, paused: Bool, action: String, playMethod: String,
                includePosition: Bool) async {
        guard let userID = source.emby?.userID,
              let client = try? await clientProvider(source) else { return }
        var payload: [String: Any] = ["ItemId": itemID, "UserId": userID, "PlaySessionId": playSessionID,
                                      "MediaSourceId": mediaSourceID,
                                      "DeviceId": client.deviceID,
                                      "IsPaused": paused, "CanSeek": true, "PlayMethod": playMethod]
        if includePosition { payload["PositionTicks"] = Int64(max(0, position) * 10_000_000) }
        let endpoint: String
        switch action {
        case "playing": endpoint = "Sessions/Playing"
        case "stopped": endpoint = "Sessions/Playing/Stopped"
        default: endpoint = "Sessions/Playing/Progress"
        }
        _ = try? await client.send(endpoint, method: "POST", body: EmbyJSON(payload))
    }

    func stopTranscoding(source: MediaSource, playSessionID: String) async {
        guard let client = try? await clientProvider(source) else { return }
        try? await client.delete("Videos/ActiveEncodings", query: ["DeviceId": client.deviceID,
                                                                   "PlaySessionId": playSessionID])
    }

    private func map(_ values: [[String: Any]], source: MediaSource, client: EmbyAPIClient) -> [MediaItem] {
        values.compactMap { value in
            guard let id = value["Id"] as? String else { return nil }
            let type = value["Type"] as? String ?? ""
            guard let name = value["Name"] as? String ?? (type == "Episode" ? "" : nil) else { return nil }
            let folder = (value["IsFolder"] as? Bool == true) || ["CollectionFolder", "UserView", "Series", "Season"].contains(type)
            guard folder || ["Movie", "Episode", "Video", "MusicVideo", "Trailer"].contains(type) else { return nil }
            let sourceID = (value["MediaSources"] as? [[String: Any]])?.first?["Id"] as? String
            let seriesImage = (value["SeriesId"] as? String).flatMap { seriesID in
                seriesID.isEmpty || seriesID == id ? nil : client.imageURL(itemID: seriesID, tag: value["SeriesPrimaryImageTag"] as? String)
            }
            let imageTags = value["ImageTags"] as? [String: String] ?? [:]
            let logoURL: URL?
            if let tag = imageTags["Logo"] {
                logoURL = client.imageURL(itemID: id, tag: tag, type: "Logo")
            } else if let parentID = value["ParentLogoItemId"] as? String, let tag = value["ParentLogoImageTag"] as? String {
                logoURL = client.imageURL(itemID: parentID, tag: tag, type: "Logo")
            } else {
                logoURL = nil
            }
            let item = MediaItem(id: MediaID(sourceID: source.id, localID: id), title: name,
                                 resource: nil,
                                 subtitle: (value["ProductionYear"] as? NSNumber).map { String($0.intValue) },
                                 isContainer: folder || type == "Series" || type == "Season",
                                 embyItemID: id, embyItemType: type, embyMediaSourceID: sourceID,
                                 imageURL: client.imageURL(itemID: id, tag: imageTags["Primary"]),
                                 fallbackImageURL: seriesImage,
                                 previewImageURL: type == "Episode" ? client.imageURL(itemID: id, tag: imageTags["Thumb"], type: "Thumb") : nil,
                                 duration: (value["RunTimeTicks"] as? NSNumber).map { $0.doubleValue / 10_000_000 },
                                 resumePosition: ((value["UserData"] as? [String: Any])?["PlaybackPositionTicks"] as? NSNumber)
                                    .map { $0.doubleValue / 10_000_000 },
                                 dateCreated: Self.parseDate(value["DateCreated"] as? String),
                                 embyPresentation: EmbyPresentation(
                                     genres: value["Genres"] as? [String] ?? [],
                                     premiereDate: Self.parseDate(value["PremiereDate"] as? String),
                                     status: value["Status"] as? String,
                                     rating: value["OfficialRating"] as? String,
                                     logoURL: logoURL,
                                     overview: value["Overview"] as? String
                                 ),
                                 isPlayed: (value["UserData"] as? [String: Any])?["Played"] as? Bool)
            return item
        }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
            ?? (try? Date.ISO8601FormatStyle().year().month().day().parse(value))
    }

    func featuredPosterCandidates(for item: MediaItem, source: MediaSource) async -> [URL] {
        guard let client = try? await clientProvider(source),
              let response = try? await client.get("Items/\(item.id.localID)/RemoteImages", query: [
                "Type": "Primary", "IncludeAllLanguages": "true", "Limit": "50"
              ]) else { return [] }
        let images = response["Images"] as? [[String: Any]] ?? []
        return Array(images.compactMap { image -> URL? in
            let language = (image["Language"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ["", "00", "zxx"].contains(language),
                  let width = image["Width"] as? Int, let height = image["Height"] as? Int, width > 0, height > width,
                  let rawURL = image["Url"] as? String, let url = URL(string: rawURL),
                  url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil else { return nil }
            return url
        }.prefix(3))
    }

    func featuredLogoData(for url: URL, source: MediaSource) async -> Data? {
        guard let client = try? await clientProvider(source), client.sameOrigin(url) else { return nil }
        return await fetchThumbnail(url, client: client)
    }

    private func externalSubtitles(media: [String: Any], itemID: String, client: EmbyAPIClient) -> [EngineExternalSubtitle] {
        let streams = media["MediaStreams"] as? [[String: Any]] ?? []
        return streams.compactMap { stream in
            guard stream["Type"] as? String == "Subtitle", stream["IsExternal"] as? Bool == true,
                  let index = stream["Index"] as? Int else { return nil }
            let format = (stream["Codec"] as? String ?? "srt").lowercased()
            let path = stream["DeliveryUrl"] as? String
                ?? "/Videos/\(itemID)/\(media["Id"] as? String ?? "")/Subtitles/\(index)/Stream.\(format)"
            guard let url = try? client.resolveMediaURL(path) else { return nil }
            let headers = client.requestHeaders(accept: "text/*,*/*;q=0.8", kind: .playback)
            return EngineExternalSubtitle(url: url, name: stream["DisplayTitle"] as? String ?? "字幕",
                                           language: stream["Language"] as? String, format: format, headers: headers)
        }
    }

    func thumbnailData(for item: MediaItem, source: MediaSource) async -> Data? {
        guard let client = try? await clientProvider(source) else { return nil }
        let primary = item.imageURL ?? client.imageURL(itemID: item.id.localID, tag: nil)
        let candidates = item.embyItemType == "Episode" ? [item.previewImageURL, primary] : [primary, item.fallbackImageURL]
        for url in candidates.compactMap({ $0 }) where client.sameOrigin(url) {
            guard !Task.isCancelled else { return nil }
            if let data = await fetchThumbnail(url, client: client) { return data }
        }
        return nil
    }

    private func fetchThumbnail(_ imageURL: URL, client: EmbyAPIClient) async -> Data? {
        var request = URLRequest(url: imageURL, timeoutInterval: 15)
        for (name, value) in client.requestHeaders(accept: "image/*,*/*;q=0.8", kind: .image) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await EmbyNetworkSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        } catch { return nil }
    }

    private static var deviceProfile: [String: Any] { [
        "Name": "Vesper iOS", "MaxStreamingBitrate": 120_000_000,
        "DirectPlayProfiles": [["Type": "Video", "Container": "mp4,m4v,mov,mkv", "VideoCodec": "h264,hevc,mpeg4", "AudioCodec": "aac,ac3,eac3,mp3,flac,alac"]],
        "TranscodingProfiles": [["Container": "ts", "Type": "Video", "VideoCodec": "h264", "AudioCodec": "aac", "Protocol": "hls", "Context": "Streaming", "MaxAudioChannels": "2"]],
        "CodecProfiles": [], "SubtitleProfiles": [["Format": "srt", "Method": "External"], ["Format": "vtt", "Method": "External"]]
    ] }
}
