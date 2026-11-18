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

    func items(for source: MediaSource, parentID: String?, startIndex: Int) async throws -> [MediaItem] {
        let client = try await clientProvider(source)
        var query = ["StartIndex": String(startIndex), "Limit": "100", "Fields": "Overview,PrimaryImageAspectRatio,MediaSources,DateCreated,ProductionYear,RunTimeTicks,UserData"]
        if let parentID { query["ParentId"] = parentID }
        else if source.emby?.userID != nil { query["ParentId"] = "" }
        query["SortBy"] = "SortName"; query["SortOrder"] = "Ascending"
        let path = source.emby?.userID.map { "Users/\($0)/Items" } ?? "Items"
        let response = try await client.get(path, query: query)
        return map(response["Items"] as? [[String: Any]] ?? [], source: source, client: client)
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
            guard let id = value["Id"] as? String, let name = value["Name"] as? String else { return nil }
            let type = value["Type"] as? String ?? ""
            let folder = (value["IsFolder"] as? Bool == true) || ["CollectionFolder", "UserView", "Series", "Season"].contains(type)
            guard folder || ["Movie", "Episode", "Video", "MusicVideo", "Trailer"].contains(type) else { return nil }
            let sourceID = (value["MediaSources"] as? [[String: Any]])?.first?["Id"] as? String
            let item = MediaItem(id: MediaID(sourceID: source.id, localID: id), title: name,
                                 resource: nil,
                                 subtitle: (value["ProductionYear"] as? NSNumber).map { String($0.intValue) },
                                 isContainer: folder || type == "Series" || type == "Season",
                                 embyItemID: id, embyMediaSourceID: sourceID,
                                 imageURL: client.imageURL(itemID: id, tag: value["ImageTags"].flatMap { ($0 as? [String: Any])?["Primary"] as? String }),
                                 duration: (value["RunTimeTicks"] as? NSNumber).map { $0.doubleValue / 10_000_000 },
                                 resumePosition: ((value["UserData"] as? [String: Any])?["PlaybackPositionTicks"] as? NSNumber)
                                    .map { $0.doubleValue / 10_000_000 })
            return item
        }
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
        guard let client = try? await clientProvider(source),
              let imageURL = item.imageURL ?? client.imageURL(itemID: item.id.localID, tag: nil) else { return nil }
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
