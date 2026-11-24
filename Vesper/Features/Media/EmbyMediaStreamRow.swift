import SwiftUI
import UIKit

struct EmbyMediaStreamRow: View {
    let stream: EmbyMediaStreamDetails

    private var title: String {
        stream.displayTitle ?? stream.title ?? "\(stream.type) \(stream.id + 1)"
    }

    private var details: [String] {
        [stream.displayLanguage, stream.language, stream.codec?.uppercased(), stream.profile,
         stream.resolution, stream.aspectRatio, stream.videoRangeType, stream.videoRange,
         stream.colorPrimaries, stream.colorTransfer, stream.colorSpace, stream.channelSummary,
         stream.sampleRate.map { "\($0) Hz" },
         stream.bitDepth.map { "\($0) bit" }, stream.bitRate.map(Self.bitRateLabel),
         stream.frameRate.map { String(format: "%.3g fps", $0) }, stream.mimeType,
         stream.deliveryMethod, stream.subtitleLocationType, stream.fileName]
            .compactMap { $0 }
    }

    private var flags: [String] {
        [stream.isDefault ? "默认" : nil,
         stream.isForced ? "强制" : nil,
         stream.isHearingImpaired ? "SDH/CC" : nil,
         stream.isExternal ? "外置" : nil,
         stream.isInterlaced ? "隔行扫描" : nil,
         stream.supportsExternalStream ? "支持外置读取" : nil,
         stream.isTextSubtitleStream ? "文本字幕" : nil]
            .compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if !flags.isEmpty {
                    Text(verbatim: flags.joined(separator: " · "))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .multilineTextAlignment(.trailing)
                }
            }
            if !details.isEmpty {
                Text(verbatim: details.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let comment = stream.comment {
                Text(verbatim: comment)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private static func bitRateLabel(_ value: Int) -> String {
        value >= 1_000_000
            ? String(format: "%.1f Mbit/s", Double(value) / 1_000_000)
            : String(format: "%.0f kbit/s", Double(value) / 1_000)
    }
}

private extension EmbyMediaStreamDetails {
    var resolution: String? {
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }

    var channelSummary: String? {
        let value = [channels.map { "\($0) 声道" }, channelLayout].compactMap { $0 }.joined(separator: " ")
        return value.isEmpty ? nil : value
    }

    var frameRate: Double? { realFrameRate ?? averageFrameRate }

    var fileName: String? {
        guard isExternal, let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

