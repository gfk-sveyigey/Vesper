import Foundation
import PlaybackContracts

/// Stable, metadata-based matching; version display names and filenames are not reliable quality labels.
enum EmbyVersionMatcher {
    struct Format {
        var container: String = ""
        var videoCodec: String = ""
        var dynamicRange: String = ""
        var width: Int? = nil
        var height: Int? = nil
        var frameRate: Double? = nil
        var audioCodec: String = ""
        var audioChannels: Int? = nil
        var bitRate: Int? = nil
    }

    static func closest(to current: EmbyMediaVersionDetails?, in candidates: [EmbyMediaVersionDetails]) -> EmbyMediaVersionDetails? {
        guard let current else { return candidates.first }
        guard let index = bestIndex(current: format(current), candidates: candidates.map(format)) else { return nil }
        return candidates[index]
    }

    static func bestIndex(current: Format, candidates: [Format]) -> Int? {
        candidates.indices.min { left, right in
            let leftRank = rank(candidates[left], against: current)
            let rightRank = rank(candidates[right], against: current)
            return leftRank == rightRank ? left < right : leftRank.lexicographicallyPrecedes(rightRank)
        }
    }

    private static func format(_ version: EmbyMediaVersionDetails) -> Format {
        let video = version.streams.first { $0.type == "Video" }
        let audio = version.streams.first { $0.type == "Audio" && $0.isDefault }
            ?? version.streams.first { $0.type == "Audio" }
        let range = [video?.videoRangeType, video?.videoRange, video?.colorTransfer]
            .compactMap { $0 }.joined(separator: " ").uppercased()
        let dynamicRange: String
        if range.contains("DOVI") || range.contains("DOLBY") || range.hasPrefix("DV") { dynamicRange = "DV" }
        else if range.contains("HLG") || range.contains("ARIB") { dynamicRange = "HLG" }
        else if range.contains("HDR10+") || range.contains("HDR10PLUS") { dynamicRange = "HDR10+" }
        else if range.contains("HDR") || range.contains("2084") || range.contains("PQ") { dynamicRange = "HDR10" }
        else if range.isEmpty { dynamicRange = "" }
        else { dynamicRange = "SDR" }
        let fileExtension = version.fileName.map { URL(fileURLWithPath: $0).pathExtension } ?? ""
        return Format(container: version.container ?? fileExtension, videoCodec: video?.codec ?? "",
                      dynamicRange: dynamicRange, width: video?.width, height: video?.height,
                      frameRate: video?.averageFrameRate ?? video?.realFrameRate, audioCodec: audio?.codec ?? "", audioChannels: audio?.channels,
                      bitRate: version.bitRate ?? video?.bitRate)
    }

    private static func normalized(_ value: String) -> String {
        let key = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ",").first.map(String.init) ?? ""
        switch key {
        case "h265", "h.265", "x265", "hev1", "hvc1": return "hevc"
        case "avc", "avc1", "h.264", "x264": return "h264"
        case "matroska": return "mkv"
        case "mov", "m4v": return "mp4"
        case "ec3", "ec-3", "e-ac-3": return "eac3"
        case "ac-3": return "ac3"
        default: return key
        }
    }

    private static func mismatch(_ candidate: String, _ reference: String) -> Double {
        let expected = normalized(reference), actual = normalized(candidate)
        if expected.isEmpty { return 0 }
        if actual == expected { return 0 }
        return actual.isEmpty ? 4 : 3
    }

    private static func distance(_ value: Int?, _ reference: Int?) -> Double {
        guard let reference, reference > 0 else { return 0 }
        guard let value, value > 0 else { return 100 }
        return abs(log(Double(value) / Double(reference)))
    }

    private static func frameRateDistance(_ value: Double?, _ reference: Double?) -> Double {
        guard let reference, reference.isFinite, reference > 0 else { return 0 }
        guard let value, value.isFinite, value > 0 else { return 100 }
        return abs(log(value / reference))
    }

    private static func rank(_ candidate: Format, against reference: Format) -> [Double] {
        // Lexicographic priority: container, video codec, HDR mode, resolution, audio, bitrate.
        [mismatch(candidate.container, reference.container),
         mismatch(candidate.videoCodec, reference.videoCodec),
         mismatch(candidate.dynamicRange, reference.dynamicRange),
         distance(candidate.width, reference.width) + distance(candidate.height, reference.height),
         frameRateDistance(candidate.frameRate, reference.frameRate),
         mismatch(candidate.audioCodec, reference.audioCodec),
         distance(candidate.audioChannels, reference.audioChannels),
         distance(candidate.bitRate, reference.bitRate)]
    }
}
