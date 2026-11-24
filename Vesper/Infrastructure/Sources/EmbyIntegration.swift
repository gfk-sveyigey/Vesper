import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PlaybackContracts

@MainActor
enum MediaSourceServices {
    static var catalog: any MediaSourceCatalogService = EmbyRepository.shared
    static var seriesCatalog: any SeriesMediaCatalogService = EmbyRepository.shared
    static var playback: any MediaSourcePlaybackService = EmbyRepository.shared
    static var reporting: any MediaSourcePlaybackReportingService = EmbyRepository.shared
    static var artwork: any MediaSourceArtworkService = EmbyRepository.shared
    static var records: any MediaSourceRecordService = EmbyRepository.shared
    static var recordRead: any MediaSourcePlaybackRecordReadService = EmbyRepository.shared
    static var routes: any MediaSourceRouteService = EmbyRepository.shared
    static var identity: any MediaSourceIdentityService = EmbyRepository.shared
}

actor EmbyRepository: MediaSourceCatalogService, SeriesMediaCatalogService, MediaSourcePlaybackService, MediaSourcePlaybackReportingService, MediaSourceArtworkService, MediaSourceRecordService, MediaSourceIdentityService, MediaSourcePlaybackRecordReadService, MediaSourceRouteService {
    static let shared = EmbyRepository()
    private let clientProvider: @MainActor @Sendable (MediaSource) throws -> EmbyAPIClient
    private var itemImages: [String: [EmbyItemImage]] = [:]

    init(clientProvider: @escaping @MainActor @Sendable (MediaSource) throws -> EmbyAPIClient = {
        try EmbyAccountStore.shared.client(for: $0)
    }) {
        self.clientProvider = clientProvider
    }

    /// Search the whole selected server, independently of the currently open library.
    func search(for source: MediaSource, query text: String, startIndex: Int = 0,
                limit: Int = 40) async throws -> EmbySearchPage {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return EmbySearchPage(items: [], nextIndex: 0, hasMore: false) }
        let client = try await clientProvider(source)
        let start = max(0, startIndex)
        let count = min(100, max(1, limit))
        let path = source.emby?.userID.map { "Users/\($0)/Items" } ?? "Items"
        let response = try await client.get(path, query: [
            "SearchTerm": text, "Recursive": "true",
            "IncludeItemTypes": "Movie,Series,Episode,Video,MusicVideo,Trailer",
            "StartIndex": String(start), "Limit": String(count),
            "EnableImages": "true", "EnableTotalRecordCount": "true",
            "Fields": "Overview,DateCreated,ProductionYear,RunTimeTicks,UserData,Genres,PremiereDate,Status,OfficialRating,CommunityRating,Studios,SeasonCount"
        ])
        try Task.checkCancellation()
        guard let values = response["Items"] as? [[String: Any]] else { throw EmbyError.invalidResponse }
        // Advance by raw server rows, even when unsupported rows are discarded by map().
        let next = start + values.count
        let total = response["TotalRecordCount"] as? Int
        let more = !values.isEmpty && (total.map { next < $0 } ?? (values.count >= count))
        return EmbySearchPage(items: map(values, source: source, client: client), nextIndex: next, hasMore: more)
    }

    func mediaLibraries(for source: MediaSource) async throws -> [MediaItem] {
        let client = try await clientProvider(source)
        let response: EmbyJSON
        if let userID = source.emby?.userID {
            response = try await client.get("Users/\(userID)/Views", query: ["IncludeExternalContent": "false"])
        } else {
            response = try await client.get("Items", query: ["Recursive": "false", "IncludeItemTypes": "CollectionFolder,Folder"])
        }
        guard let values = response["Items"] as? [[String: Any]] else { throw EmbyError.invalidResponse }
        var seen = Set<MediaID>()
        return map(values, source: source, client: client).filter { $0.isContainer && seen.insert($0.id).inserted }
    }

    func latestMedia(for source: MediaSource, libraryID: String) async throws -> [MediaItem] {
        try await latestMedia(for: source, parentID: libraryID, limit: 20).items
    }

    func featuredMedia(for source: MediaSource) async throws -> [MediaItem] {
        try await latestMedia(for: source, parentID: nil, limit: 10).items
    }

    func latestMediaGroup(for source: MediaSource, libraryID: String) async throws -> (items: [MediaItem], totalCount: Int?) {
        try await latestMedia(for: source, parentID: libraryID, limit: 20)
    }

    func sourceSummary(for source: MediaSource) async throws -> EmbySourceSummary {
        let client = try await clientProvider(source)
        let path = source.emby?.userID.map { "Users/\($0)/Items" } ?? "Items"
        func count(_ type: String) async throws -> Int {
            let response = try await client.get(path, query: [
                "Recursive": "true", "IncludeItemTypes": type, "Limit": "1",
                "EnableTotalRecordCount": "true"
            ])
            guard let total = response["TotalRecordCount"] as? Int else { throw EmbyError.invalidResponse }
            return total
        }
        async let movies = count("Movie")
        async let series = count("Series")
        async let lastPlayed = client.get(path, query: [
            "Recursive": "true", "IncludeItemTypes": "Movie,Episode", "Filters": "IsPlayed",
            "SortBy": "DatePlayed", "SortOrder": "Descending", "Limit": "1",
            "Fields": "UserData"
        ])
        let lastResponse = try await lastPlayed
        let dateText = (((lastResponse["Items"] as? [[String: Any]])?.first?["UserData"] as? [String: Any])?["LastPlayedDate"] as? String)
        let latestDate = dateText.flatMap { value -> Date? in
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: value)
        }
        return EmbySourceSummary(movieCount: try await movies, seriesCount: try await series, lastPlayed: latestDate)
    }

    private func latestMedia(for source: MediaSource, parentID: String?, limit: Int) async throws -> (items: [MediaItem], totalCount: Int?) {
        let client = try await clientProvider(source)
        let path = source.emby?.userID.map { "Users/\($0)/Items" } ?? "Items"
        let titleTypes = EmbyBrowseScope.titles.itemTypes ?? []
        var query = [
            "Recursive": "true",
            "IncludeItemTypes": titleTypes.joined(separator: ","),
            "SortBy": "DateCreated", "SortOrder": "Descending", "StartIndex": "0", "Limit": String(limit),
            "EnableImages": "true", "EnableTotalRecordCount": "true",
            "Fields": "DateCreated,ProductionYear,RunTimeTicks,UserData,Genres,PremiereDate,Status,OfficialRating,CommunityRating,Studios,SeasonCount"
        ]
        if let parentID { query["ParentId"] = parentID }
        let response = try await client.get(path, query: query)
        guard let values = response["Items"] as? [[String: Any]] else { throw EmbyError.invalidResponse }
        var seen = Set<MediaID>()
        return (Array(map(values, source: source, client: client)
            .filter { titleTypes.contains($0.embyItemType ?? "") && seen.insert($0.id).inserted }.prefix(limit)),
                response["TotalRecordCount"] as? Int)
    }

    func serverName(for source: MediaSource) async throws -> String? {
        let client = try await clientProvider(source)
        let info = try await client.get("System/Info/Public")
        let serverName = (info["ServerName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let productName = (info["ProductName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return serverName?.isEmpty == false ? serverName : productName
    }

    func alternateRoutes(for source: MediaSource) async throws -> [EmbyServerRoute] {
        let client = try await clientProvider(source)
        return try await Self.alternateRoutes(client: client, primaryRoute: source.emby?.primaryRoute)
    }

    static func alternateRoutes(client: EmbyAPIClient, primaryRoute: String?) async throws -> [EmbyServerRoute] {
        let response = try await client.get("System/Ext/ServerDomains")
        guard response["ok"] as? Bool == true,
              let rows = response["data"] as? [[String: Any]] else { throw EmbyError.invalidResponse }
        let primaryKey = primaryRoute.map(EmbyRouteOptions.key)
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  let address = (row["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !address.isEmpty else { return nil }
            let configuration = EmbySourceConfiguration(title: "", note: "", serverAddress: address, username: "")
            guard (try? EmbyAPIClient(configuration: configuration, token: nil, deviceID: "validation")) != nil else { return nil }
            let key = EmbyRouteOptions.key(address)
            guard key != primaryKey, seen.insert(key).inserted else { return nil }
            return EmbyServerRoute(name: name, address: address)
        }
    }

    func items(for source: MediaSource, parentID: String?, startIndex: Int,
               limit: Int = 100, sortBy: String = "SortName", sortOrder: String = "Ascending",
               scope: EmbyBrowseScope = .children) async throws -> [MediaItem] {
        let client = try await clientProvider(source)
        var query = ["StartIndex": String(startIndex), "Limit": String(limit), "Fields": "Overview,MediaSources,DateCreated,ProductionYear,RunTimeTicks,UserData,Genres,PremiereDate,Status,OfficialRating,CommunityRating,Studios,SeasonCount",
                     "SortBy": sortBy, "SortOrder": sortOrder]
        switch scope {
        case .person(let person):
            if let id = person.id {
                query["PersonIds"] = id
            } else {
                guard !person.name.isEmpty else { return [] }
                query["Person"] = person.name
            }
        default:
            if let parentID { query["ParentId"] = parentID }
            else if source.emby?.userID != nil && scope != .favorites { query["ParentId"] = "" }
            if scope == .favorites { query["Filters"] = "IsFavorite" }
        }
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

    func detailMetadata(for item: MediaItem, source: MediaSource) async throws -> EmbyDetailMetadata {
        let (client, response) = try await detailSnapshot(for: item, source: source)
        let credits = (response["People"] as? [[String: Any]] ?? []).enumerated().compactMap { index, value -> EmbyCredit? in
            guard let name = (value["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            let id = (value["Id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let image = id.map { id in
                MediaItem(id: MediaID(sourceID: source.id, localID: id), title: name, resource: nil,
                          embyItemType: "Person",
                          imageURL: client.imageURL(itemID: id, tag: value["PrimaryImageTag"] as? String, width: 200))
            }
            let role = (value["Role"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? value["Type"] as? String ?? ""
            return EmbyCredit(id: "\(index)", person: EmbyPerson(id: id, name: name), role: role, image: image)
        }
        let providers = response["ProviderIds"] as? [String: String] ?? [:]
        let traktID = providers.first(where: { $0.key.caseInsensitiveCompare("Trakt") == .orderedSame })?.value
        var links = (response["ExternalUrls"] as? [[String: Any]] ?? []).compactMap { value -> EmbyExternalLink? in
            guard let name = value["Name"] as? String, let raw = value["Url"] as? String,
                  !(name.localizedCaseInsensitiveContains("trakt") && traktID != nil && item.embyItemType != "Episode"),
                  let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { return nil }
            return EmbyExternalLink(name: name, url: url)
        }
        if item.embyItemType != "Episode", let traktID, !traktID.isEmpty, traktID.utf8.allSatisfy({ (48...57).contains($0) }),
           let url = URL(string: "https://trakt.tv/\(item.isEmbySeries ? "shows" : "movies")/\(traktID)") {
            links.append(EmbyExternalLink(name: "Trakt", url: url))
        }
        for (provider, name, base) in [("Imdb", "IMDb", "https://www.imdb.com/title/"),
                                       ("Tmdb", "TMDb", item.isEmbySeries ? "https://www.themoviedb.org/tv/" : "https://www.themoviedb.org/movie/"),
                                       ("Douban", "豆瓣", "https://movie.douban.com/subject/")] {
            guard !(provider == "Tmdb" && item.embyItemType == "Episode"),
                  let id = providers.first(where: { $0.key.caseInsensitiveCompare(provider) == .orderedSame })?.value,
                  !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }),
                  !links.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  let url = URL(string: base + id) else { continue }
            links.append(EmbyExternalLink(name: name, url: url))
        }
        var seen = Set<URL>()
        var resolved = map([response.values], source: source, client: client).first ?? item
        resolved.embyMediaSourceID = item.embyMediaSourceID ?? resolved.embyMediaSourceID
        let parentSeries: MediaItem?
        if resolved.embyItemType == "Episode",
           let id = response["SeriesId"] as? String, !id.isEmpty, id != item.id.localID,
           let name = response["SeriesName"] as? String, !name.isEmpty {
            parentSeries = MediaItem(id: MediaID(sourceID: source.id, localID: id), title: name,
                                     resource: nil, isContainer: true, embyItemID: id, embyItemType: "Series",
                                     imageURL: client.imageURL(itemID: id, tag: response["SeriesPrimaryImageTag"] as? String))
        } else {
            parentSeries = nil
        }
        let mediaDetails = itemDetails(response, item: resolved, source: source)
        return EmbyDetailMetadata(item: resolved, credits: credits, links: links.filter { seen.insert($0.url).inserted },
                                  video: mediaDetails.video, mediaVersions: mediaDetails.mediaVersions,
                                  series: parentSeries, seasonNumber: response["ParentIndexNumber"] as? Int,
                                  episodeNumber: response["IndexNumber"] as? Int,
                                  seriesInformation: seriesInformation(response))
    }

    private func seriesInformation(_ response: EmbyJSON) -> [EmbySeriesInformationGroup] {
        guard response["Type"] as? String == "Series" else { return [] }
        func text(_ value: Any?) -> String? {
            guard let value, !(value is NSNull) else { return nil }
            if let string = value as? String {
                return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
            }
            if let values = value as? [String] { return values.isEmpty ? nil : values.joined(separator: "、") }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        func formatted(_ key: String, value: Any?) -> String? {
            if ["DateCreated", "DateModified", "PremiereDate", "EndDate", "LastPlayedDate"].contains(key),
               let raw = value as? String {
                return raw.replacingOccurrences(of: "T", with: " ")
            }
            if key == "RunTimeTicks" || key == "PlaybackPositionTicks", let ticks = value as? NSNumber {
                let seconds = ticks.doubleValue / 10_000_000
                guard seconds.isFinite, seconds >= 0 else { return nil }
                return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
            }
            if ["Played", "IsFavorite", "LockData"].contains(key), let flag = value as? Bool { return flag ? "是" : "否" }
            if key == "Status", let status = value as? String {
                return ["Continuing": "连载中", "Ended": "已完结"][status] ?? status
            }
            if key == "AirDays", let days = value as? [String] {
                let names = ["Sunday": "周日", "Monday": "周一", "Tuesday": "周二", "Wednesday": "周三", "Thursday": "周四", "Friday": "周五", "Saturday": "周六"]
                return days.isEmpty ? nil : days.map { names[$0] ?? $0 }.joined(separator: "、")
            }
            if key == "Studios", let values = value as? [[String: Any]] { return text(values.compactMap { $0["Name"] as? String }) }
            return text(value)
        }
        let definitions: [(String, String, [(String, String)])] = [
            ("basic", "基本资料", [("Name", "名称"), ("OriginalTitle", "原名"), ("Overview", "简介"), ("Taglines", "宣传语"), ("ProductionYear", "年份"), ("OfficialRating", "内容分级"), ("CustomRating", "自定义分级"), ("CommunityRating", "社区评分"), ("CriticRating", "影评评分")]),
            ("airing", "播出信息", [("Status", "播出状态"), ("EndDate", "完结时间"), ("AirDays", "播出日期"), ("SeasonCount", "季数")]),
            ("production", "制作与分类", [("Genres", "类型"), ("Studios", "制作公司／电视台"), ("ProductionLocations", "制作地区"), ("Tags", "标签"), ("PreferredMetadataLanguage", "元数据语言"), ("PreferredMetadataCountryCode", "元数据地区")]),
            ("library", "媒体库资料", [("DateModified", "修改时间"), ("LocationType", "存储类型"), ("PrimaryImageAspectRatio", "海报宽高比")])
        ]
        var result = definitions.compactMap { id, title, definitions -> EmbySeriesInformationGroup? in
            let fields = definitions.compactMap { key, label -> EmbySeriesInformationField? in
                guard let value = formatted(key, value: response[key]) else { return nil }
                return .init(id: key, label: label, value: value)
            }
            return fields.isEmpty ? nil : .init(id: id, title: title, fields: fields)
        }
        return result
    }

    func seriesSeasonCount(for series: MediaItem, source: MediaSource) async throws -> Int {
        guard series.id.sourceID == source.id else { throw EmbyError.invalidResponse }
        let client = try await clientProvider(source)
        var query = ["EnableTotalRecordCount": "true"]
        if let userID = source.emby?.userID { query["UserId"] = userID }
        let response = try await client.get("Shows/\(series.id.localID)/Seasons", query: query)
        guard let rows = response["Items"] as? [[String: Any]] else { throw EmbyError.invalidResponse }
        return response["TotalRecordCount"] as? Int ?? rows.count
    }

    func seriesEpisodes(for series: MediaItem, source: MediaSource, limit: Int? = nil) async throws -> [EmbyEpisode] {
        let client = try await clientProvider(source)
        let pageLimit = min(100, max(1, limit ?? 100))
        var query = ["Fields": "Overview,MediaStreams,MediaSources,RunTimeTicks", "Limit": String(pageLimit),
                     "SortBy": "ParentIndexNumber,IndexNumber", "SortOrder": "Ascending",
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
                                            played: (row["UserData"] as? [String: Any])?["Played"] as? Bool,
                                            is4K: video.contains { ($0["Width"] as? Int ?? 0) >= 3800 },
                                            dolbyVision: dolbyVision, dolbyAtmos: dolbyAtmos))
                if let limit, episodes.count >= limit { break }
            }
            if let limit, episodes.count >= limit { break }
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
        var query = ["Limit": "20", "Fields": "Genres,PremiereDate,Overview,Status,OfficialRating,CommunityRating,Studios"]
        if let userID = source.emby?.userID { query["UserId"] = userID }
        let response = try await client.get("Items/\(item.id.localID)/Similar", query: query)
        let rows = response["Items"] as? [[String: Any]] ?? []
        var seen: Set<MediaID> = [item.id]
        return map(rows, source: source, client: client).filter {
            ($0.isEmbySeries || $0.embyItemType == "Movie") && seen.insert($0.id).inserted
        }
    }

    // Public user actions accept the item itself: Movie, Series and Episode all use
    // the same endpoints. Never substitute a media-source/version ID for the item ID.
    func setPlayed(_ played: Bool, for item: MediaItem, source: MediaSource) async throws {
        let (client, userID) = try await userActionClient(item, source: source)
        _ = try await client.send("Users/\(userID)/PlayedItems/\(item.id.localID)",
                                  method: played ? "POST" : "DELETE")
    }

    func setFavorite(_ favorite: Bool, for item: MediaItem, source: MediaSource) async throws {
        let (client, userID) = try await userActionClient(item, source: source)
        _ = try await client.send("Users/\(userID)/FavoriteItems/\(item.id.localID)",
                                  method: favorite ? "POST" : "DELETE")
    }

    func clearProgress(for item: MediaItem, source: MediaSource) async throws {
        try await setPlayed(false, for: item, source: source)
    }

    private func userActionClient(_ item: MediaItem, source: MediaSource) async throws -> (EmbyAPIClient, String) {
        guard item.id.sourceID == source.id, !item.id.localID.isEmpty else { throw EmbyError.invalidResponse }
        guard let userID = source.emby?.userID else { throw EmbyError.missingAccount }
        return (try await clientProvider(source), userID)
    }

    // Shared dispatcher used by PlaybackSession's per-item serialized write queue.
    func updatePlaybackRecord(for item: MediaItem, source: MediaSource, change: EmbyPlaybackRecordChange) async throws {
        switch change {
        case .clearProgress: try await clearProgress(for: item, source: source)
        case .setPlayed(let value): try await setPlayed(value, for: item, source: source)
        case .setFavorite(let value): try await setFavorite(value, for: item, source: source)
        }
    }

    func details(for item: MediaItem, source: MediaSource) async throws -> EmbyItemDetails {
        let (_, response) = try await detailSnapshot(for: item, source: source)
        return itemDetails(response, item: item, source: source)
    }

    /// Shared Movie/Series/Episode detail transport and error context.
    private func detailSnapshot(for item: MediaItem, source: MediaSource) async throws -> (EmbyAPIClient, EmbyJSON) {
        do {
            guard item.id.sourceID == source.id else { throw EmbyError.invalidResponse }
            let client = try await clientProvider(source)
            return (client, try await fetchDetailItem(item, source: source, client: client))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EmbyOperationFailure(operation: "获取媒体详情", itemID: item.id.localID,
                                       sourceID: source.id, reason: error.localizedDescription)
        }
    }

    private func fetchDetailItem(_ item: MediaItem, source: MediaSource, client: EmbyAPIClient) async throws -> EmbyJSON {
        let id = item.id.localID
        if let userID = source.emby?.userID {
            return try await client.get("Users/\(userID)/Items/\(id)")
        }

        let fields = "Overview,Genres,People,ProviderIds,ExternalUrls,MediaSources,MediaStreams,OriginalTitle,Taglines,Studios,ProductionLocations,Tags,DateModified,Path,EndDate,AirDays,SeasonCount,CustomRating,CommunityRating,CriticRating,PreferredMetadataLanguage,PreferredMetadataCountryCode,PrimaryImageAspectRatio"
        let response = try await client.get("Items", query: ["Ids": id, "Limit": "1", "Fields": fields])
        guard let rows = response["Items"] as? [[String: Any]],
              let row = rows.first(where: { $0["Id"] as? String == id }) else {
            throw EmbyError.invalidResponse
        }
        return EmbyJSON(row)
    }

    private func itemDetails(_ response: EmbyJSON, item: MediaItem, source: MediaSource) -> EmbyItemDetails {
        let sources = response["MediaSources"] as? [[String: Any]] ?? []
        let media = sources.first(where: { $0["Id"] as? String == item.embyMediaSourceID }) ?? sources.first ?? [:]
        let mediaRows = sources.isEmpty ? [response.values] : sources
        let mediaVersions = mediaRows.enumerated().compactMap { offset, version -> EmbyMediaVersionDetails? in
            guard let id = version["Id"] as? String ?? (offset == 0 ? item.embyMediaSourceID : nil) else { return nil }
            let path = version["Path"] as? String
            let streams = version["MediaStreams"] as? [[String: Any]] ?? (offset == 0 ? response["MediaStreams"] as? [[String: Any]] ?? [] : [])
            let defaultAudioIndex = version["DefaultAudioStreamIndex"] as? Int
            let defaultSubtitleIndex = version["DefaultSubtitleStreamIndex"] as? Int
            let parsedStreams = streams.enumerated().compactMap { index, stream -> EmbyMediaStreamDetails? in
                guard let type = stream["Type"] as? String,
                      ["Video", "Audio", "Subtitle"].contains(type) else { return nil }
                let streamIndex = stream["Index"] as? Int ?? index
                let sourceDefaultIndex = type == "Audio" ? defaultAudioIndex
                    : type == "Subtitle" ? defaultSubtitleIndex : nil
                return EmbyMediaStreamDetails(
                    id: streamIndex, type: type,
                    displayTitle: stream["DisplayTitle"] as? String,
                    title: stream["Title"] as? String,
                    language: stream["Language"] as? String,
                    displayLanguage: stream["DisplayLanguage"] as? String,
                    codec: stream["Codec"] as? String,
                    profile: stream["Profile"] as? String,
                    channels: stream["Channels"] as? Int,
                    channelLayout: stream["ChannelLayout"] as? String,
                    sampleRate: stream["SampleRate"] as? Int,
                    bitDepth: stream["BitDepth"] as? Int,
                    bitRate: stream["BitRate"] as? Int,
                    width: stream["Width"] as? Int,
                    height: stream["Height"] as? Int,
                    aspectRatio: stream["AspectRatio"] as? String,
                    videoRange: stream["VideoRange"] as? String,
                    videoRangeType: stream["VideoRangeType"] as? String,
                    colorTransfer: stream["ColorTransfer"] as? String,
                    colorPrimaries: stream["ColorPrimaries"] as? String,
                    colorSpace: stream["ColorSpace"] as? String,
                    averageFrameRate: (stream["AverageFrameRate"] as? NSNumber)?.doubleValue,
                    realFrameRate: (stream["RealFrameRate"] as? NSNumber)?.doubleValue,
                    isDefault: stream["IsDefault"] as? Bool ?? (sourceDefaultIndex == streamIndex),
                    isForced: stream["IsForced"] as? Bool ?? false,
                    isHearingImpaired: stream["IsHearingImpaired"] as? Bool ?? false,
                    isExternal: stream["IsExternal"] as? Bool ?? false,
                    isInterlaced: stream["IsInterlaced"] as? Bool ?? false,
                    isTextSubtitleStream: stream["IsTextSubtitleStream"] as? Bool ?? false,
                    supportsExternalStream: stream["SupportsExternalStream"] as? Bool ?? false,
                    deliveryMethod: stream["DeliveryMethod"] as? String,
                    subtitleLocationType: stream["SubtitleLocationType"] as? String,
                    mimeType: stream["MimeType"] as? String,
                    path: stream["Path"] as? String,
                    comment: stream["Comment"] as? String
                )
            }
            return EmbyMediaVersionDetails(
                id: id, name: version["Name"] as? String ?? id,
                fileName: path.map { URL(fileURLWithPath: $0).lastPathComponent },
                container: version["Container"] as? String,
                size: (version["Size"] as? NSNumber).flatMap { $0.int64Value > 0 ? $0.int64Value : nil },
                bitRate: version["Bitrate"] as? Int,
                duration: (version["RunTimeTicks"] as? NSNumber).map { $0.doubleValue / 10_000_000 },
                supportsDirectPlay: version["SupportsDirectPlay"] as? Bool,
                supportsDirectStream: version["SupportsDirectStream"] as? Bool,
                supportsTranscoding: version["SupportsTranscoding"] as? Bool,
                protocolName: version["Protocol"] as? String,
                mediaType: version["Type"] as? String,
                mimeType: version["MimeType"] as? String,
                isRemote: version["IsRemote"] as? Bool,
                hasMixedProtocols: version["HasMixedProtocols"] as? Bool,
                defaultAudioStreamIndex: defaultAudioIndex,
                defaultSubtitleStreamIndex: defaultSubtitleIndex,
                streams: parsedStreams
            )
        }
        var fields: [PlaybackDetailField] = []
        if let container = media["Container"] as? String { fields.append(.init(label: "容器格式", value: container)) }
        if let bitrate = media["Bitrate"] as? NSNumber {
            fields.append(.init(label: "总码率", value: String(format: "%.2f Mbit/s", bitrate.doubleValue / 1_000_000)))
        }
        let streams = media["MediaStreams"] as? [[String: Any]] ?? response["MediaStreams"] as? [[String: Any]] ?? []
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
        return EmbyItemDetails(video: video, versions: versions, mediaVersions: mediaVersions)
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
        // Playback engines without arbitrary HTTP headers authenticate via the URL.
        let addApiKey = true
        let directURL = media["DirectStreamUrl"] as? String
        let url: URL
        if let directURL { url = try client.resolveMediaURL(directURL, includeToken: addApiKey) }
        else {
            url = try client.mediaURL("Videos/\(itemID)/stream", query: ["static": "true", "MediaSourceId": mediaSourceID,
                                                                           "PlaySessionId": playSessionID, "DeviceId": client.deviceID],
                                      includeToken: addApiKey)
        }
        var headers = client.playbackHeaders()
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
                                    resumePosition: progressTicks.map { $0.doubleValue / 10_000_000 }, subtitles: subtitles)
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
              let url = try? client.resolveMediaURL(stream, includeToken: true) else { throw EmbyError.invalidResponse }
        var headers = client.playbackHeaders()
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
        let mappedAt = Date()
        return values.compactMap { value -> MediaItem? in
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
            let played = (value["UserData"] as? [String: Any])?["Played"] as? Bool
            var item = MediaItem(id: MediaID(sourceID: source.id, localID: id), title: name,
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
                                     overview: value["Overview"] as? String,
                                     communityRating: (value["CommunityRating"] as? NSNumber)?.doubleValue,
                                     studios: ((value["Studios"] as? [[String: Any]]) ?? []).compactMap { $0["Name"] as? String },
                                     seasonCount: (value["SeasonCount"] as? NSNumber)?.intValue
                                 ),
                                 isPlayed: played,
                                 embyPlayedFetchedAt: played == nil ? nil : mappedAt)
            item.isFavorite = (value["UserData"] as? [String: Any])?["IsFavorite"] as? Bool
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
            guard let width = image["Width"] as? Int, let height = image["Height"] as? Int, width > 0, height > width,
                  let rawURL = image["Url"] as? String, let url = URL(string: rawURL),
                  url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil else { return nil }
            return url
        }.prefix(3))
    }

    func featuredLogoData(for item: MediaItem, source: MediaSource) async -> Data? {
        guard let client = try? await clientProvider(source),
              !Task.isCancelled else { return nil }
        // The mapped URL includes the server tag and may belong to a parent item.
        if let url = item.embyPresentation?.logoURL, client.sameOrigin(url),
           let data = await fetchThumbnail(url, client: client) { return data }
        return nil
    }

    private func externalSubtitles(media: [String: Any], itemID: String, client: EmbyAPIClient) -> [EngineExternalSubtitle] {
        let streams = media["MediaStreams"] as? [[String: Any]] ?? []
        return streams.compactMap { stream in
            guard stream["Type"] as? String == "Subtitle", stream["IsExternal"] as? Bool == true,
                  let index = stream["Index"] as? Int else { return nil }
            let format = (stream["Codec"] as? String ?? "srt").lowercased()
            let path = stream["DeliveryUrl"] as? String
                ?? "/Videos/\(itemID)/\(media["Id"] as? String ?? "")/Subtitles/\(index)/Stream.\(format)"
            guard let url = try? client.resolveMediaURL(path, includeToken: true) else { return nil }
            let headers = client.playbackHeaders()
            return EngineExternalSubtitle(url: url, name: stream["DisplayTitle"] as? String ?? "字幕",
                                           language: stream["Language"] as? String, format: format, headers: headers)
        }
    }

    /// Single server-artwork entry point. Remote provider posters remain a separate,
    /// explicit carousel policy; ordinary posters always prefer the server default Primary.
    func artworkData(for item: MediaItem, source: MediaSource, purpose: EmbyArtworkPurpose,
                     orientation: EmbyImageOrientation = .portrait, allowsRemotePrimary: Bool = false,
                     prefersLandscapeMovieArtwork: Bool = false) async -> Data? {
        switch purpose {
        case .logo:
            return await featuredLogoData(for: item, source: source)
        case .avatar:
            guard let client = try? await clientProvider(source),
                  let url = item.imageURL, client.sameOrigin(url) else { return nil }
            return await fetchThumbnail(url, client: client)
        case .poster, .thumbnail:
            return await thumbnailData(for: item, source: source, orientation: orientation, allowsRemotePrimary: allowsRemotePrimary,
                                       prefersLandscapeMovieArtwork: prefersLandscapeMovieArtwork)
        }
    }

    func thumbnailData(for item: MediaItem, source: MediaSource,
                       orientation: EmbyImageOrientation, allowsRemotePrimary: Bool = false,
                       prefersLandscapeMovieArtwork: Bool = false) async -> Data? {
        guard let client = try? await clientProvider(source) else { return nil }
        if item.embyItemType == "Person" {
            guard let imageURL = item.imageURL, client.sameOrigin(imageURL) else { return nil }
            return await fetchThumbnail(imageURL, client: client)
        }

        // Episode artwork retains the original server-default Thumb → Primary policy.
        if item.embyItemType == "Episode" {
            let candidates = [
                item.previewImageURL ?? client.imageURL(itemID: item.id.localID, tag: nil, type: "Thumb"),
                item.imageURL ?? client.imageURL(itemID: item.id.localID, tag: nil)
            ]
            for url in candidates.compactMap({ $0 }) where client.sameOrigin(url) {
                guard !Task.isCancelled else { return nil }
                if let data = await fetchThumbnail(url, client: client) { return data }
            }
            return nil
        }

        if prefersLandscapeMovieArtwork && item.embyItemType == "Movie" {
            let types = ["Primary", "Thumb", "Thumbnail", "Backdrop", "Screenshot"]
            let candidates = await selectedImages(for: item, source: source, client: client,
                                                  preferredTypes: types, preferredOrientation: .landscape,
                                                  allowedTypes: Set(types), requiresOrientation: true)
            for url in candidates where client.sameOrigin(url) {
                guard !Task.isCancelled else { return nil }
                if let data = await fetchThumbnail(url, client: client) { return data }
            }
        }

        let preferredOrientation = orientation == .square ? nil : orientation
        let isPosterItem = ["Movie", "Series"].contains(item.embyItemType ?? "")
        let preferredTypes: [String]
        if isPosterItem || item.isContainer {
            preferredTypes = ["Primary", "Thumbnail", "Thumb", "Screenshot"]
        } else if orientation == .landscape {
            preferredTypes = ["Thumb", "Screenshot", "Primary", "Thumbnail"]
        } else {
            preferredTypes = ["Primary", "Thumbnail", "Thumb", "Screenshot"]
        }
        if isPosterItem || item.isContainer,
           let primaryURL = item.imageURL ?? client.imageURL(itemID: item.id.localID, tag: nil),
           client.sameOrigin(primaryURL),
           let data = await fetchThumbnail(primaryURL, client: client) {
            return data
        }
        if isPosterItem && allowsRemotePrimary {
            for url in await featuredPosterCandidates(for: item, source: source) {
                guard !Task.isCancelled else { return nil }
                var request = URLRequest(url: url, timeoutInterval: 8)
                request.httpShouldHandleCookies = false
                guard let (data, response) = try? await EmbyNetworkSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count <= 8 * 1024 * 1024 else { continue }
                #if canImport(ImageIO)
                guard CGImageSourceCreateWithData(data as CFData, nil) != nil else { continue }
                #endif
                return data
            }
        }
        for image in await selectedImages(for: item, source: source, client: client,
                                          preferredTypes: preferredTypes, preferredOrientation: preferredOrientation,
                                          allowedTypes: Set(preferredTypes),
                                          requiresOrientation: item.isContainer && !isPosterItem && orientation == .landscape)
            where client.sameOrigin(image) {
            guard !Task.isCancelled else { return nil }
            if let data = await fetchThumbnail(image, client: client) { return data }
        }
        return nil
    }

    func screenshotURLs(for item: MediaItem, source: MediaSource) async -> [URL] {
        guard let client = try? await clientProvider(source) else { return [] }
        let urls = await selectedImages(for: item, source: source, client: client,
                                        preferredTypes: ["Screenshot"], allowedTypes: ["Screenshot"])
        return urls.filter { client.sameOrigin($0) }
    }

    func screenshotData(at url: URL, source: MediaSource) async -> Data? {
        guard let client = try? await clientProvider(source), client.sameOrigin(url) else { return nil }
        return await fetchThumbnail(url, client: client)
    }

    private func selectedImages(for item: MediaItem, source: MediaSource, client: EmbyAPIClient,
                                preferredTypes: [String], preferredOrientation: EmbyImageOrientation? = nil,
                                allowedTypes: Set<String>? = nil, requiresOrientation: Bool = false) async -> [URL] {
        let cacheKey = "\(AppCacheStore.scope(for: source))|\(item.id.localID)"
        let images: [EmbyItemImage]
        if let cached = itemImages[cacheKey] {
            images = cached
        } else {
            guard let response = try? await client.get("Items/\(item.id.localID)/Images"),
                  let rows = response["Items"] as? [[String: Any]] else { return [] }
            let supportedTypes: Set<String> = ["Primary", "Art", "Backdrop", "Banner", "Logo", "Thumb",
                                               "Disc", "Box", "Screenshot", "Menu", "Chapter", "BoxRear",
                                               "Thumbnail", "LogoLight", "LogoLightColor"]
            images = rows.compactMap { row in
                guard let type = row["ImageType"] as? String,
                      supportedTypes.contains(type),
                      let index = row["ImageIndex"] as? Int,
                      let width = row["Width"] as? Int, width > 0,
                      let height = row["Height"] as? Int, height > 0 else { return nil }
                return EmbyItemImage(type: type, index: index, width: width, height: height)
            }
            itemImages[cacheKey] = images
        }

        // Cache the full inventory; purpose-specific filters must not poison other requests.
        let candidates = images.filter { image in
            if let allowedTypes, !allowedTypes.contains(image.type) { return false }
            if requiresOrientation, let preferredOrientation {
                return preferredOrientation == .landscape ? image.width > image.height : image.width < image.height
            }
            return true
        }
        let ranked = candidates.sorted { lhs, rhs in
            let leftType = preferredTypes.firstIndex(of: lhs.type) ?? preferredTypes.count
            let rightType = preferredTypes.firstIndex(of: rhs.type) ?? preferredTypes.count
            if leftType != rightType { return leftType < rightType }
            if let preferredOrientation {
                let leftLandscape = lhs.width > lhs.height
                let rightLandscape = rhs.width > rhs.height
                let leftMatches = leftLandscape == (preferredOrientation == .landscape) && lhs.width != lhs.height
                let rightMatches = rightLandscape == (preferredOrientation == .landscape) && rhs.width != rhs.height
                if leftMatches != rightMatches { return leftMatches }
            }
            return lhs.index < rhs.index
        }
        return ranked.compactMap { image in
            client.imageURL(itemID: item.id.localID, tag: nil, type: image.type, index: image.index)
        }
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



// MARK: - External intro/credits databases









extension EmbyRepository {
    func traktShowIdentity(for show: MediaItem, source: MediaSource) async throws -> TraktMediaIdentity? {
        let (_, detail) = try await detailSnapshot(for: show, source: source)
        guard detail["Type"] as? String == "Series" else { return nil }
        let ids = TraktMediaIdentity.supportedIDs(detail["ProviderIds"] as? [String: String] ?? [:])
        guard !ids.isEmpty else { return nil }
        return TraktMediaIdentity(kind: "show", ids: ids)
    }

    func traktIdentity(for item: MediaItem, source: MediaSource) async throws -> TraktMediaIdentity? {
        let (client, detail) = try await detailSnapshot(for: item, source: source)
        let type = detail["Type"] as? String
        guard type == "Movie" || type == "Episode" else { return nil }
        let ids = TraktMediaIdentity.supportedIDs(detail["ProviderIds"] as? [String: String] ?? [:])
        if !ids.isEmpty { return TraktMediaIdentity(kind: type == "Movie" ? "movie" : "episode", ids: ids) }
        guard type == "Episode", let seriesID = detail["SeriesId"] as? String, !seriesID.isEmpty,
              let season = detail["ParentIndexNumber"] as? Int, season >= 0,
              let episode = detail["IndexNumber"] as? Int, episode > 0 else { return nil }
        let series = MediaItem(id: MediaID(sourceID: source.id, localID: seriesID), title: "", resource: nil)
        let parent = try await fetchDetailItem(series, source: source, client: client)
        let showIDs = TraktMediaIdentity.supportedIDs(parent["ProviderIds"] as? [String: String] ?? [:])
        guard !showIDs.isEmpty else { return nil }
        return TraktMediaIdentity(kind: "episode", ids: showIDs, season: season, episode: episode)
    }

    func skipIdentity(for item: MediaItem, source: MediaSource) async throws -> EmbySkipIdentity? {
        let (client, detail) = try await detailSnapshot(for: item, source: source)
        let type = detail["Type"] as? String
        if type == "Episode" {
            guard let seriesID = detail["SeriesId"] as? String,
                  let season = detail["ParentIndexNumber"] as? Int,
                  let episode = detail["IndexNumber"] as? Int else { return nil }
            let series = MediaItem(id: MediaID(sourceID: source.id, localID: seriesID), title: "", resource: nil)
            let parent = try await fetchDetailItem(series, source: source, client: client)
            return EmbySkipIdentity(providers: parent["ProviderIds"] as? [String: String] ?? [:], season: season, episode: episode)
        }
        guard type == "Movie" || type == "Video" else { return nil }
        return EmbySkipIdentity(providers: detail["ProviderIds"] as? [String: String] ?? [:], season: nil, episode: nil)
    }
}
