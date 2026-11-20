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
    let mediaVersions: [EmbyMediaVersionDetails]
}

struct EmbyMediaStreamDetails: Hashable, Sendable, Identifiable {
    let id: Int
    let type: String
    let displayTitle: String?
    let title: String?
    let language: String?
    let displayLanguage: String?
    let codec: String?
    let profile: String?
    let channels: Int?
    let channelLayout: String?
    let sampleRate: Int?
    let bitDepth: Int?
    let bitRate: Int?
    let width: Int?
    let height: Int?
    let aspectRatio: String?
    let videoRange: String?
    let videoRangeType: String?
    let colorTransfer: String?
    let colorPrimaries: String?
    let colorSpace: String?
    let averageFrameRate: Double?
    let realFrameRate: Double?
    let isDefault: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    let isExternal: Bool
    let isInterlaced: Bool
    let isTextSubtitleStream: Bool
    let supportsExternalStream: Bool
    let deliveryMethod: String?
    let subtitleLocationType: String?
    let mimeType: String?
    let path: String?
    let comment: String?
}

struct EmbyMediaVersionDetails: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let fileName: String?
    let container: String?
    let size: Int64?
    let bitRate: Int?
    let duration: Double?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let protocolName: String?
    let mediaType: String?
    let mimeType: String?
    let isRemote: Bool?
    let hasMixedProtocols: Bool?
    let defaultAudioStreamIndex: Int?
    let defaultSubtitleStreamIndex: Int?
    let streams: [EmbyMediaStreamDetails]
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

    static func featured(in groups: [Self], count: Int = 10) -> [MediaItem] {
        let candidates = groups.filter { $0.id != librariesID }.flatMap(\.items)
        var seen = Set<MediaID>()
        return Array(candidates.filter { seen.insert($0.id).inserted }.shuffled().prefix(count))
    }
}

struct EmbyEpisode: Identifiable, Sendable {
    var item: MediaItem
    let season: Int
    let number: Int?
    var played: Bool?
    let is4K: Bool
    let dolbyVision: Bool
    let dolbyAtmos: Bool
    var id: MediaID { item.id }
}

struct EmbyPerson: Hashable, Sendable {
    let id: String?
    let name: String
}

struct EmbyCredit: Identifiable, Sendable {
    let id: String
    let person: EmbyPerson
    let role: String
    let image: MediaItem?
}

struct EmbyExternalLink: Identifiable, Sendable {
    let name: String
    let url: URL
    var id: URL { url }
}

struct EmbyDetailMetadata: Sendable {
    let item: MediaItem
    let credits: [EmbyCredit]
    let links: [EmbyExternalLink]
    let video: PlaybackVideoDetails
    let mediaVersions: [EmbyMediaVersionDetails]
    let series: MediaItem?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let seriesInformation: [EmbySeriesInformationGroup]
}

struct EmbySeriesInformationField: Sendable, Identifiable {
    let id: String
    let label: String
    let value: String
}

struct EmbySeriesInformationGroup: Sendable, Identifiable {
    let id: String
    let title: String
    let fields: [EmbySeriesInformationField]
}

private struct EmbyItemImage: Sendable {
    let type: String
    let index: Int
    let width: Int
    let height: Int
}

enum EmbyBrowseScope: Equatable, Sendable {
    case children, titles, episodes, favorites
    case person(EmbyPerson)

    var cacheKey: String {
        switch self {
        case .children: "children"
        case .titles: "titles"
        case .episodes: "episodes"
        case .favorites: "favorites"
        case .person(let person): person.id.map { "person:id:\($0)" } ?? "person:name:\(person.name)"
        }
    }

    var itemTypes: [String]? {
        switch self {
        case .children: nil
        case .titles, .person: ["Movie", "Series", "Video", "MusicVideo", "Trailer"]
        case .favorites: ["Movie", "Series", "Episode", "Video", "MusicVideo", "Trailer"]
        case .episodes: ["Episode"]
        }
    }
}

enum EmbyPlaybackRecordChange: Sendable {
    case clearProgress
    case setPlayed(Bool)
}

actor EmbyRepository {
    static let shared = EmbyRepository()
    private let clientProvider: @MainActor @Sendable (MediaSource) throws -> EmbyAPIClient
    private var itemImages: [String: [EmbyItemImage]] = [:]

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
        return map(values, source: source, client: client).filter { $0.isContainer && seen.insert($0.id).inserted }
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
            "Fields": "DateCreated,ProductionYear,RunTimeTicks,UserData,Genres,PremiereDate,Status,OfficialRating,CommunityRating,Studios,SeasonCount"
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
        var query = ["StartIndex": String(startIndex), "Limit": String(limit), "Fields": "Overview,PrimaryImageAspectRatio,MediaSources,DateCreated,ProductionYear,RunTimeTicks,UserData,Genres,PremiereDate,Status,OfficialRating,CommunityRating,Studios,SeasonCount",
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
        let client = try await clientProvider(source)
        let response = try await fetchDetailItem(item, source: source, client: client)
        let credits = (response["People"] as? [[String: Any]] ?? []).enumerated().compactMap { index, value -> EmbyCredit? in
            guard let name = (value["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            let id = (value["Id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let image = id.map { id in
                MediaItem(id: MediaID(sourceID: source.id, localID: id), title: name, resource: nil,
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

    func updatePlaybackRecord(for item: MediaItem, source: MediaSource, change: EmbyPlaybackRecordChange) async throws {
        guard let userID = source.emby?.userID else { throw EmbyError.missingAccount }
        let client = try await clientProvider(source)
        let path = "Users/\(userID)/Items/\(item.id.localID)"
        let stored = try await client.get(path)
        guard var data = stored["UserData"] as? [String: Any] else { throw EmbyError.invalidResponse }
        switch change {
        case .clearProgress:
            data["PlaybackPositionTicks"] = 0
        case .setPlayed(let played):
            data["Played"] = played
        }
        _ = try await client.send("\(path)/UserData", method: "POST", body: EmbyJSON(data))
    }

    func details(for item: MediaItem, source: MediaSource) async throws -> EmbyItemDetails {
        let client = try await clientProvider(source)
        let response = try await fetchDetailItem(item, source: source, client: client)
        return itemDetails(response, item: item, source: source)
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
                size: (version["Size"] as? NSNumber)?.int64Value,
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
            let item = MediaItem(id: MediaID(sourceID: source.id, localID: id), title: name,
                                 resource: nil,
                                 subtitle: (value["ProductionYear"] as? NSNumber).map { String($0.intValue) },
                                 isContainer: folder || type == "Series" || type == "Season",
                                 embyItemID: id, embyItemType: type, embyMediaSourceID: sourceID,
                                 imageURL: client.imageURL(itemID: id, tag: imageTags["Primary"]),
                                 fallbackImageURL: seriesImage,
                                 previewImageURL: type == "Episode" ? client.imageURL(itemID: id, tag: imageTags["Thumb"], type: "Thumb") : nil,
                                 primaryImageAspectRatio: (value["PrimaryImageAspectRatio"] as? NSNumber)?.doubleValue,
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

    func featuredLogoData(for item: MediaItem, source: MediaSource) async -> Data? {
        guard let client = try? await clientProvider(source),
              !Task.isCancelled else { return nil }
        let logoTypes: Set<String> = ["Logo", "LogoLight", "LogoLightColor"]
        for image in await selectedImages(for: item, source: source, client: client,
                                          preferredTypes: ["Logo", "LogoLight", "LogoLightColor"],
                                          allowedTypes: logoTypes)
            where client.sameOrigin(image) {
            if let data = await fetchThumbnail(image, client: client) { return data }
        }
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
            guard let url = try? client.resolveMediaURL(path) else { return nil }
            let headers = client.requestHeaders(accept: "text/*,*/*;q=0.8", kind: .playback)
            return EngineExternalSubtitle(url: url, name: stream["DisplayTitle"] as? String ?? "字幕",
                                           language: stream["Language"] as? String, format: format, headers: headers)
        }
    }

    func thumbnailData(for item: MediaItem, source: MediaSource, aspectRatio: Double = 2.0 / 3.0) async -> Data? {
        guard let client = try? await clientProvider(source) else { return nil }
        let itemAspectRatio = item.primaryImageAspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (item.embyItemType == "Episode" ? 16.0 / 9.0 : 2.0 / 3.0)
        let preferredTypes = itemAspectRatio >= 1
            ? ["Thumb", "Screenshot", "Backdrop", "Primary", "Thumbnail"]
            : ["Primary", "Thumbnail", "Thumb", "Backdrop", "Screenshot"]
        for image in await selectedImages(for: item, source: source, client: client,
                                          preferredTypes: preferredTypes, targetAspectRatio: itemAspectRatio)
            where client.sameOrigin(image) {
            guard !Task.isCancelled else { return nil }
            if let data = await fetchThumbnail(image, client: client) { return data }
        }
        return nil
    }

    private func selectedImages(for item: MediaItem, source: MediaSource, client: EmbyAPIClient,
                                preferredTypes: [String], targetAspectRatio: Double = 1,
                                allowedTypes: Set<String>? = nil) async -> [URL] {
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
                      allowedTypes == nil || allowedTypes!.contains(type),
                      let index = row["ImageIndex"] as? Int,
                      let width = row["Width"] as? Int, width > 0,
                      let height = row["Height"] as? Int, height > 0 else { return nil }
                return EmbyItemImage(type: type, index: index, width: width, height: height)
            }
            itemImages[cacheKey] = images
        }

        let ranked = images.sorted { lhs, rhs in
            let leftType = preferredTypes.firstIndex(of: lhs.type) ?? preferredTypes.count
            let rightType = preferredTypes.firstIndex(of: rhs.type) ?? preferredTypes.count
            if leftType != rightType { return leftType < rightType }
            let leftRatio = Double(lhs.width) / Double(lhs.height)
            let rightRatio = Double(rhs.width) / Double(rhs.height)
            let leftScore = abs(log(leftRatio / max(0.1, targetAspectRatio)))
            let rightScore = abs(log(rightRatio / max(0.1, targetAspectRatio)))
            if leftScore != rightScore { return leftScore < rightScore }
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
