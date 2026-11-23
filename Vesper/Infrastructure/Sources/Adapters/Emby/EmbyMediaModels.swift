import Foundation
import PlaybackContracts

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

enum EmbyTrackPreferences {
    static let audioLanguageKey = "emby.audioLanguage"
    static let subtitleLanguageKey = "emby.subtitleLanguage"
    static let disableMissingSubtitleKey = "emby.disableMissingSubtitle"
    static let languages = [("", "未指定"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁体中文"), ("eng", "英语"), ("jpn", "日语"),
                            ("kor", "韩语"), ("fra", "法语"), ("deu", "德语"), ("spa", "西班牙语"),
                            ("ita", "意大利语"), ("por", "葡萄牙语"), ("rus", "俄语"),
                            ("ara", "阿拉伯语"), ("hin", "印地语"), ("tha", "泰语"), ("vie", "越南语")]
    static func normalized(_ language: String) -> String {
        let value = language.lowercased().replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init) ?? ""
        switch value {
        case "zh", "chi", "zho": return "zho"
        case "en", "eng": return "eng"
        case "ja", "jpn": return "jpn"
        case "ko", "kor": return "kor"
        case "fr", "fre", "fra": return "fra"
        case "de", "ger", "deu": return "deu"
        case "es", "spa": return "spa"
        case "it", "ita": return "ita"
        case "pt", "por": return "por"
        case "ru", "rus": return "rus"
        case "ar", "ara": return "ara"
        case "hi", "hin": return "hin"
        case "th", "tha": return "tha"
        case "vi", "vie": return "vie"
        default: return value
        }
    }
    static func matches(_ stream: EmbyMediaStreamDetails, language: String) -> Bool {
        guard normalized(stream.language ?? "") == normalized(language) else { return false }
        guard language == "zh-Hans" || language == "zh-Hant" else { return true }
        let code = (stream.language ?? "").lowercased().replacingOccurrences(of: "_", with: "-")
        let text = [stream.displayTitle, stream.title, stream.displayLanguage].compactMap { $0 }
            .joined(separator: " ").lowercased()
        let traditional = code.contains("hant") || code.hasSuffix("-tw") || code.hasSuffix("-hk")
            || code.hasSuffix("-mo") || text.contains("繁") || text.contains("traditional")
        let simplified = code.contains("hans") || code.hasSuffix("-cn") || code.hasSuffix("-sg")
            || text.contains("简") || text.contains("簡") || text.contains("simplified")
        // Generic chi/zho cannot reliably distinguish scripts: treat as unmatched.
        return language == "zh-Hant" ? traditional : simplified
    }

    static func selection(_ streams: [EmbyMediaStreamDetails], type: String) -> Int? {
        let tracks = streams.filter { $0.type == type }
        let audio = type == "Audio"
        let language = UserDefaults.standard.string(forKey: audio ? audioLanguageKey : subtitleLanguageKey) ?? ""
        guard !language.isEmpty else { return tracks.first?.id }
        if let match = tracks.first(where: { matches($0, language: language) }) {
            return match.id
        }
        return !audio && UserDefaults.standard.bool(forKey: disableMissingSubtitleKey)
            ? nil : tracks.first?.id
    }
}

enum EmbyBrowsingSettings {
    static let fullRenderingKey = "emby.fullRendering"
}

struct EmbyMediaGroup: Identifiable, Sendable {
    static let librariesID = "all-media"
    let id: String
    let title: String
    var items: [MediaItem]
    var totalCount: Int? = nil
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

enum EmbyImageOrientation: String, Equatable, Sendable {
    case portrait, landscape, square
}

enum EmbyArtworkPurpose: Sendable {
    case poster
    case thumbnail
    case avatar
    case logo
}

struct EmbyOperationFailure: LocalizedError, Sendable {
    let operation: String
    let itemID: String
    let sourceID: UUID
    let reason: String
    var errorDescription: String? { "\(operation)失败：\(reason)（条目 \(itemID)）" }
}


struct EmbyItemImage: Sendable {
    let type: String
    let index: Int
    let width: Int
    let height: Int
}

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
    let resumePosition: Double?
    let subtitles: [EngineExternalSubtitle]
    var bitRate: Double? = nil
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
struct EmbyMediaGroup: Identifiable, Sendable {
    static let librariesID = "all-media"
    let id: String
    let title: String
    var items: [MediaItem]
    var totalCount: Int? = nil
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
enum EmbyImageOrientation: String, Equatable, Sendable {
    case portrait, landscape, square
}
enum EmbyArtworkPurpose: Sendable {
    case poster
    case thumbnail
    case avatar
    case logo
}
struct EmbyOperationFailure: LocalizedError, Sendable {
    let operation: String
    let itemID: String
    let sourceID: UUID
    let reason: String
    var errorDescription: String? { "\(operation)失败：\(reason)（条目 \(itemID)）" }
}

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
    let resumePosition: Double?
    let subtitles: [EngineExternalSubtitle]
    var bitRate: Double? = nil
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
