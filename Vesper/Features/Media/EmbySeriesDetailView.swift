import SwiftUI
import UIKit

struct EmbyPreviewFacts: View {
    let item: MediaItem

    var body: some View {
        let metadata = item.embyPresentation
        let date = metadata?.premiereDate.flatMap { date -> String? in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let year = components.year else { return nil }
            return String(year)
        }
        let kind: String? = switch item.embyItemType {
        case "Series": String(localized: "剧集")
        case "Movie": String(localized: "电影")
        default: nil
        }
        let tags = ([kind].compactMap { $0 } + (metadata?.genres ?? []).prefix(3))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " · ")
        let details = [date, tags.isEmpty ? nil : tags].compactMap { $0 }.joined(separator: "  ")
        if !details.isEmpty {
            Text(verbatim: details)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

struct EmbySeriesHeroFooter: View {
    let series: MediaItem
    let season: Int?
    let seasonCount: Int
    let episodes: [EmbyEpisode]
    var runtime: String? = nil
    var selectedEpisode: EmbyEpisode? = nil
    var seriesSeasonCount = 1
    var selectedEpisodeIsPlayed = false
    var playSelectedEpisode: () -> Void = {}
    var toggleSelectedEpisodePlayed: () -> Void = {}
    private let buttonHeight: CGFloat = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selectedEpisode {
                HStack(spacing: 10) {
                    Button(action: playSelectedEpisode) {
                        Label(selectedEpisodeLabel(selectedEpisode), systemImage: "play.fill")
                            .font(.system(size: 16))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: buttonHeight * 3.8, height: buttonHeight)
                    }
                    .buttonStyle(SeriesHeroPlayButtonStyle())
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)

                    Button {
                        withAnimation(.snappy(duration: 0.32)) {
                            toggleSelectedEpisodePlayed()
                        }
                    } label: {
                        Image(systemName: selectedEpisodeIsPlayed ? "checkmark" : "plus")
                            .font(.system(size: 16))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: buttonHeight, height: buttonHeight)
                    }
                    .buttonStyle(SeriesHeroWatchButtonStyle())
                    .clipShape(Circle())
                    .accessibilityLabel(selectedEpisodeIsPlayed ? "标记为未观看" : "标记为已观看")
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }

            Text(verbatim: series.embyPresentation?.overview ?? "")
                .font(.subheadline)
                .lineLimit(2, reservesSpace: true)

            if !facts.isEmpty || !episodes.isEmpty {
                HStack(spacing: 7) {
                    Text(verbatim: facts.joined(separator: " · "))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if episodes.contains(where: \.is4K) {
                        Image(systemName: "4k.tv")
                            .accessibilityLabel("4K")
                    }
                    if episodes.contains(where: \.dolbyVision) {
                        Text("Dolby Vision").fontWeight(.semibold)
                    }
                    if episodes.contains(where: \.dolbyAtmos) {
                        Text("Dolby Atmos").fontWeight(.semibold)
                    }
                }
                .font(.subheadline)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }

    private var facts: [String] {
        var facts = [series.subtitle].compactMap { $0 }
        if let runtime { facts.append(runtime) }
        if let season {
            if seasonCount > 1 {
                facts.append(String(localized: "\(embySeasonName(season))/共\(seasonCount)季"))
            }
            facts.append(String(localized: "\(episodes.count)集"))
        }
        return facts
    }

    private func selectedEpisodeLabel(_ episode: EmbyEpisode) -> String {
        let number = String(format: "%02d", episode.number ?? 0)
        if seriesSeasonCount <= 1 { return String(localized: "开始播放 E\(number)") }
        return String(localized: "开始播放 S\(String(format: "%02d", episode.season))E\(number)")
    }
}

private struct SeriesHeroPlayButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(VesperTheme.background)
            .background(Color(uiColor: .label).opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct SeriesHeroWatchButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(uiColor: .label))
            .background(Color(uiColor: .systemGray5).opacity(configuration.isPressed ? 0.82 : 1))
            .overlay(Circle().strokeBorder(Color(uiColor: .opaqueSeparator), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private func embySeasonName(_ number: Int) -> String {
    number == 0 ? String(localized: "特别篇") : String(localized: "第\(number)季")
}

private struct EmbyMediaStreamRow: View {
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

struct EmbyMediaDetailView: View {
    let source: MediaSource
    let series: MediaItem
    var showsCloseButton = false
    var startsWithCarouselInformationHidden = false
    var onCarouselDetailReady: (() -> Void)? = nil
    var episode: EmbyEpisode? = nil
    var parentSeries: MediaItem? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var playback: PlaybackSession
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @State private var metadata: EmbyDetailMetadata?
    @State private var selectedMediaSourceID: String?
    @State private var selectedAudioIndex: Int?
    @State private var selectedSubtitleIndex: Int?
    @State private var episodes: [EmbyEpisode] = []
    @State private var seasonNumbers: [Int] = []
    @State private var similar: [MediaItem] = []
    @State private var leadingEpisode: MediaID?
    @State private var selectedEpisodeID: MediaID?
    @State private var pendingInitialEpisodeID: MediaID?
    @State private var episodeShelfAtEnd = false
    @State private var selectedSeason: Int?
    @State private var seasonMovesForward = true
    @State private var openedEpisodeID: MediaID?
    @State private var hasScrolled = false
    @Namespace private var recommendationZoom
    @State private var busy: Set<MediaID> = []
    @State private var openedRecommendation: MediaItem?
    @State private var openedPerson: EmbyPerson?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var isLoading = true
    @State private var loadedSeriesID: MediaID?
    @State private var reloadID = 0
    @State private var clearedServerProgress = false
    @State private var carouselDetailReady = false
    @State private var detailDataReady = false
    @State private var preparedArtwork: [MediaID: Data] = [:]
    private var detailContentReady: Bool {
        detailDataReady && (!series.isEmbySeries || pendingInitialEpisodeID == nil)
    }

    private var item: MediaItem { metadata?.item ?? series }
    private var selectedVersion: EmbyMediaVersionDetails? {
        metadata?.mediaVersions.first(where: { $0.id == selectedMediaSourceID })
            ?? metadata?.mediaVersions.first(where: { $0.id == item.embyMediaSourceID })
            ?? metadata?.mediaVersions.first
    }
    private var playableItem: MediaItem {
        var result = item
        if let selectedVersion {
            result.embyMediaSourceID = selectedVersion.id
            result.subtitle = selectedVersion.name
            result.duration = selectedVersion.duration ?? result.duration
        }
        return result
    }
    private var isEpisode: Bool { episode != nil || item.embyItemType == "Episode" }

    private var runtime: String? {
        guard let duration = playableItem.duration, duration.isFinite, duration > 0 else { return nil }
        return Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private var episodeTitle: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? episodeNumberLabel ?? String(localized: "单集") : title
    }

    private var episodeNumberLabel: String? {
        (metadata?.episodeNumber ?? episode?.number).map { String(localized: "第\($0)集") }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if isEpisode { episodeHero } else { hero }
                    VStack(alignment: .leading, spacing: CGFloat(layout[.groupSpacing])) {
                        if series.isEmbySeries {
                            episodeSection(viewportWidth: width)
                        }
                        VStack(alignment: .leading, spacing: CGFloat(layout[.groupSpacing])) {
                            if !series.isEmbySeries {
                                versionSelectionSection
                                playbackSection
                                if isEpisode { parentSeriesSection }
                                technicalSection
                                if let loadError {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(verbatim: loadError).font(.footnote).foregroundStyle(.secondary)
                                        Button("重试") { reloadID += 1 }
                                    }
                                    .padding(.horizontal, CGFloat(layout[.endPadding]))
                                }
                            }
                            similarSection
                            creditsSection
                            linksSection
                            seriesInformationSection
                        }
                        .opacity(detailContentReady ? 1 : 0)
                    }
                    .allowsHitTesting(detailContentReady)
                    .accessibilityHidden(!detailContentReady)
                    .animation(reduceMotion ? nil : .easeIn(duration: 0.3), value: detailContentReady)
                }
                .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollEdgeEffectHidden(true, for: .top)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 0.5
            } action: { _, hasScrolled in
                self.hasScrolled = hasScrolled
            }
        }
        .overlay(alignment: .top) {
            VesperMediaStatusBarBlur(isVisible: hasScrolled)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(VesperTheme.background.ignoresSafeArea())
        .navigationTitle(isEpisode ? episodeTitle : item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
            if showsCloseButton {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .navigationDestination(item: $openedEpisodeID) { id in
            if let episode = episodes.first(where: { $0.id == id }) {
                EmbyMediaDetailView(source: source, series: episode.item, episode: episode, parentSeries: item)
            }
        }
        .navigationDestination(item: $openedRecommendation) { item in
            recommendationDestination(for: item)
        }
        .navigationDestination(item: $openedPerson) { person in
            EmbyPersonWorksView(source: source, person: person)
        }
        .alert("无法更新观看记录", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) {
            Button("好", role: .cancel) { actionError = nil }
        } message: { Text(verbatim: actionError ?? "") }
        .task(id: "\(series.id.sourceID):\(series.id.localID):\(reloadID)") {
            guard loadedSeriesID != series.id else { return }
            await loadDetail()
        }
    }

    // A recommendation can open another instance of this view.
    private func recommendationDestination(for item: MediaItem) -> AnyView {
        if item.isEmbySeries {
            if isEpisode { return AnyView(EmbyMediaDetailView(source: source, series: item)) }
            return AnyView(
                EmbyMediaDetailView(source: source, series: item)
                    .navigationTransition(.zoom(sourceID: item.id, in: recommendationZoom))
            )
        }
        return AnyView(EmbyMediaDetailView(source: source, series: item))
    }

    private var hero: some View {
        GeometryReader { geometry in
            EmbyFeaturedPage(source: source, item: item, size: geometry.size,
                             artwork: nil, artworkIsPrepared: false, featuredArtwork: nil,
                             featuredArtworkIsPrepared: false,
                             showsInformation: detailContentReady && (!startsWithCarouselInformationHidden || carouselDetailReady),
                             seriesFooter: EmbySeriesHeroFooter(series: item, season: selectedSeason,
                                                               seasonCount: seasonNumbers.count,
                                                               episodes: episodes.filter { $0.season == selectedSeason },
                                                               runtime: series.isEmbySeries ? nil : runtime,
                                                               selectedEpisode: episodes.first { $0.id == selectedEpisodeID },
                                                               seriesSeasonCount: seasonNumbers.count,
                                                               selectedEpisodeIsPlayed: episodes.first { $0.id == selectedEpisodeID }
                                                                .map { playback.effectivePlayed(for: $0.item) } ?? false,
                                                               playSelectedEpisode: playSelectedEpisode,
                                                               toggleSelectedEpisodePlayed: toggleSelectedEpisodePlayed),
                             seriesFooterOpacity: detailContentReady
                                && (!startsWithCarouselInformationHidden || carouselDetailReady) ? 1 : 0)
                .animation(reduceMotion ? nil : .easeIn(duration: 0.3), value: detailContentReady)
                .modifier(EmbyPosterStretch(geometry: geometry))
        }
        .aspectRatio(EmbyPosterLayout.aspectRatio, contentMode: .fit)
    }

    private var episodeHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaThumbnail(source: source, item: item, aspectRatio: 16.0 / 9.0,
                           imageOrientation: .landscape, cornerRadius: 0)
            VStack(alignment: .leading, spacing: 8) {
                let number = episodeNumberLabel == episodeTitle ? nil : episodeNumberLabel
                let season = (metadata?.seasonNumber ?? episode?.season).map(embySeasonName)
                let context = [(parentSeries ?? metadata?.series)?.title, season, number]
                    .compactMap { $0 }.joined(separator: " · ")
                if !context.isEmpty {
                    Text(verbatim: context).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(verbatim: episodeTitle).font(.title.bold()).accessibilityAddTraits(.isHeader)
                if let overview = item.embyPresentation?.overview, !overview.isEmpty {
                    Text(verbatim: overview).font(.subheadline)
                }
            }
            .padding(.horizontal, CGFloat(layout[.endPadding]))
        }
    }

    private var playbackSection: some View {
        let played = playback.effectivePlayed(for: item)
        let serverPosition = clearedServerProgress ? nil : item.resumePosition
        let position = serverPosition ?? playback.savedProgress(for: item)
        let progressDuration = playableItem.duration.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        return VStack(alignment: .leading, spacing: 8) {
            if isEpisode || played || (position > 0 && progressDuration != nil) {
                HStack(spacing: 10) {
                    if played {
                        Label("已观看", systemImage: "checkmark.circle")
                    }
                    if position > 0, let progressDuration {
                        ProgressView(value: min(position, progressDuration), total: progressDuration)
                            .accessibilityLabel("播放进度")
                    }
                    if isEpisode {
                        Text(verbatim: runtime ?? String(localized: "未知时长"))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    var playable = playableItem
                    if clearedServerProgress { playable.resumePosition = 0 }
                    let audio = selectedVersion?.streams.first { $0.type == "Audio" && $0.id == selectedAudioIndex }
                    let subtitle = selectedVersion?.streams.first { $0.type == "Subtitle" && $0.id == selectedSubtitleIndex }
                    playback.play(playable, in: source, queue: [playable], audio: audio, subtitle: subtitle,
                                  streams: selectedVersion?.streams ?? [])
                } label: {
                    Label(position > 0 && !played ? "继续播放" : "播放", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if source.emby?.userID != nil {
                    Menu {
                        Button(played ? "标记为未观看" : "标记为已观看",
                               systemImage: played ? "circle" : "checkmark.circle") {
                            playback.setPlayed(!played, for: item, source: source) { actionError = $0 }
                        }
                        if position > 0 {
                            Button("清除播放进度", systemImage: "clock.arrow.circlepath") {
                                clearItemProgress()
                            }
                            .disabled(busy.contains(item.id))
                        }
                    } label: {
                        Label("观看记录", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
            }
        }
        .padding(.horizontal, CGFloat(layout[.endPadding]))
    }

    @ViewBuilder
    private var versionSelectionSection: some View {
        let versions = metadata?.mediaVersions ?? []
        if versions.count > 1, let selectedVersion {
            VStack(alignment: .leading, spacing: 8) {
                Text("媒体文件").font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Menu {
                    ForEach(versions) { version in
                        Button {
                            selectedMediaSourceID = version.id
                            resetTrackSelection(for: version)
                        } label: {
                            if version.id == selectedVersion.id {
                                Label(versionMenuTitle(version), systemImage: "checkmark")
                            } else {
                                Text(verbatim: versionMenuTitle(version))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: selectedVersion.name).font(.subheadline.weight(.medium))
                            Text(verbatim: versionSummary(selectedVersion))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VesperTheme.mediaCardBackground, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择媒体文件")
                .accessibilityValue(versionMenuTitle(selectedVersion))
            }
            .padding(.horizontal, CGFloat(layout[.endPadding]))
        }
    }

    private func versionMenuTitle(_ version: EmbyMediaVersionDetails) -> String {
        let details = [version.container?.uppercased(), version.size.map(Self.byteCountLabel)]
            .compactMap { $0 }.joined(separator: " · ")
        return details.isEmpty ? version.name : "\(version.name) · \(details)"
    }

    private func versionSummary(_ version: EmbyMediaVersionDetails) -> String {
        [version.fileName, version.container?.uppercased(), version.mimeType, version.protocolName,
         version.size.map(Self.byteCountLabel),
         version.bitRate.map(Self.bitRateLabel), version.duration.map(Self.durationLabel)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private static func byteCountLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func bitRateLabel(_ bitsPerSecond: Int) -> String {
        bitsPerSecond >= 1_000_000
            ? String(format: "%.1f Mbit/s", Double(bitsPerSecond) / 1_000_000)
            : String(format: "%.0f kbit/s", Double(bitsPerSecond) / 1_000)
    }

    private static func durationLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    @ViewBuilder
    private var parentSeriesSection: some View {
        if let parent = parentSeries ?? metadata?.series {
            Button {
                openedRecommendation = parent
            } label: {
                HStack(spacing: 12) {
                    MediaThumbnail(source: source, item: parent, imageOrientation: .portrait)
                        .frame(width: 44)
                        .mediaArtworkBorder()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("所属剧集").font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: parent.title).font(.headline)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, CGFloat(layout[.endPadding]))
        }
    }

    @ViewBuilder
    private var technicalSection: some View {
        if let selectedVersion {
            VStack(alignment: .leading, spacing: 14) {
                Text("媒体信息").font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                if let fileName = selectedVersion.fileName {
                    LabeledContent("文件名", value: fileName)
                }
                if let container = selectedVersion.container {
                    LabeledContent("容器格式", value: container.uppercased())
                }
                if let size = selectedVersion.size {
                    LabeledContent("文件大小", value: Self.byteCountLabel(size))
                }
                if let bitRate = selectedVersion.bitRate {
                    LabeledContent("总码率", value: Self.bitRateLabel(bitRate))
                }
                if let duration = selectedVersion.duration {
                    LabeledContent("时长", value: Self.durationLabel(duration))
                }
                if let protocolName = selectedVersion.protocolName {
                    LabeledContent("传输协议", value: protocolName)
                }
                if let mediaType = selectedVersion.mediaType {
                    LabeledContent("媒体类型", value: mediaType)
                }
                if let mimeType = selectedVersion.mimeType {
                    LabeledContent("MIME 类型", value: mimeType)
                }
                capabilitySummary(selectedVersion)
                ForEach(["Video", "Audio", "Subtitle"], id: \.self) { type in
                    let streams = selectedVersion.streams.filter { $0.type == type }
                    if !streams.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(streamSectionTitle(type, count: streams.count))
                                .font(.system(size: 16, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                            if type == "Subtitle" {
                                Button {
                                    selectedSubtitleIndex = nil
                                } label: {
                                    HStack {
                                        Text("关闭字幕")
                                        Spacer()
                                        if selectedSubtitleIndex == nil { Image(systemName: "checkmark") }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            ForEach(streams) { stream in
                                if type == "Video" {
                                    EmbyMediaStreamRow(stream: stream)
                                } else {
                                    Button {
                                        if type == "Audio" { selectedAudioIndex = stream.id }
                                        else { selectedSubtitleIndex = stream.id }
                                    } label: {
                                        HStack {
                                            EmbyMediaStreamRow(stream: stream)
                                            if (type == "Audio" ? selectedAudioIndex : selectedSubtitleIndex) == stream.id {
                                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityAddTraits((type == "Audio" ? selectedAudioIndex : selectedSubtitleIndex) == stream.id ? .isSelected : [])
                                }
                            }
                        }
                    }
                }
            }
            .font(.subheadline)
            .padding(.horizontal, CGFloat(layout[.endPadding]))
        } else if let video = metadata?.video, video.dimensions != nil || !video.technical.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("媒体信息").font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                if let dimensions = video.dimensions {
                    LabeledContent("分辨率", value: dimensions)
                }
                ForEach(Array(video.technical.enumerated()), id: \.offset) { _, field in
                    LabeledContent(field.label, value: field.value)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, CGFloat(layout[.endPadding]))
        }
    }

    @ViewBuilder
    private func capabilitySummary(_ version: EmbyMediaVersionDetails) -> some View {
        let capabilities = [
            version.supportsDirectPlay == true ? "直接播放" : nil,
            version.supportsDirectStream == true ? "直接串流" : nil,
            version.supportsTranscoding == true ? "支持转码" : nil,
            version.isRemote == true ? "远程媒体" : nil,
            version.hasMixedProtocols == true ? "混合协议" : nil
        ].compactMap { $0 }
        if !capabilities.isEmpty {
            Text(verbatim: capabilities.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func streamSectionTitle(_ type: String, count: Int) -> String {
        let title = type == "Video" ? "视频轨道" : type == "Audio" ? "音轨" : "字幕"
        return "\(title)（\(count)）"
    }

    @ViewBuilder
    private func episodeSection(viewportWidth: CGFloat) -> some View {
        if !episodes.isEmpty {
            let margin = CGFloat(layout[.endPadding])
            let cardWidth = min(layout.episodeCardWidth, max(1, viewportWidth - margin * 2))
            VStack(alignment: .leading, spacing: 0) {
                seasonMenu
                    .opacity(detailContentReady ? 1 : 0)
                    .padding(.horizontal, CGFloat(layout[.endPadding]))
                    .padding(.vertical, CGFloat(layout[.titlePadding]))
                episodeShelf(cardWidth: cardWidth)
                    .opacity(detailContentReady ? 1 : 0)
                    .overlay {
                        if !detailContentReady {
                            episodeLoadingPlaceholders(viewportWidth: viewportWidth)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, CGFloat(layout[.itemVerticalPadding] + layout[.scrollPadding]))
            }
        } else if isLoading {
            VStack(alignment: .leading, spacing: 0) {
                seasonMenu
                    .hidden()
                    .padding(.horizontal, CGFloat(layout[.endPadding]))
                    .padding(.vertical, CGFloat(layout[.titlePadding]))
                episodeLoadingPlaceholders(viewportWidth: viewportWidth)
                    .padding(.vertical, CGFloat(layout[.itemVerticalPadding] + layout[.scrollPadding]))
            }
        } else if let loadError {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: loadError).font(.footnote).foregroundStyle(.secondary)
                Button("重试") { Task { await loadDetail() } }
            }
            .padding(.horizontal, CGFloat(layout[.endPadding]))
        } else if !isLoading {
            Text("暂无分集").foregroundStyle(.secondary).padding(.horizontal, CGFloat(layout[.endPadding]))
        }
    }

    private func episodeLoadingPlaceholders(viewportWidth: CGFloat) -> some View {
        let margin = CGFloat(layout[.endPadding])
        let cardWidth = min(layout.episodeCardWidth, max(1, viewportWidth - margin * 2))
        return ScrollView(.horizontal) {
            LazyHStack(spacing: CGFloat(layout[.itemSpacing])) {
                ForEach(0..<2, id: \.self) { _ in
                    MediaCardBackdrop()
                        .frame(width: cardWidth, height: layout.episodeCardHeight)
                        .mediaArtworkBorder()
                }
            }
            .scrollTargetLayout()
        }
        .scrollClipDisabled()
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never, anchor: .leading))
        .scrollIndicators(.hidden)
        .accessibilityLabel("正在加载分集")
    }

    @ViewBuilder
    private var seasonMenu: some View {
        if seasonNumbers.count > 1 {
            Menu {
                ForEach(seasonNumbers, id: \.self) { season in
                    Button {
                        guard let first = episodes.first(where: { $0.season == season }) else { return }
                        selectSeason(season, firstEpisode: first.id)
                    } label: {
                        if selectedSeason == season {
                            Label(embySeasonName(season), systemImage: "checkmark")
                        } else {
                            Text(verbatim: embySeasonName(season))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    seasonTitle
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            seasonTitle
        }
    }

    private var seasonTitle: some View {
        let season = selectedSeason ?? seasonNumbers.first ?? 1
        let entry: Edge = seasonMovesForward ? .bottom : .top
        let exit: Edge = seasonMovesForward ? .top : .bottom
        return ZStack(alignment: .leading) {
            Text(verbatim: embySeasonName(season))
                .id(season)
                .transition(reduceMotion ? .identity : .asymmetric(insertion: .move(edge: entry), removal: .move(edge: exit)))
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.primary)
        .clipped()
    }

    private func selectSeason(_ season: Int, firstEpisode: MediaID? = nil) {
        if let selectedSeason, selectedSeason != season {
            seasonMovesForward = season > selectedSeason
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
            selectedSeason = season
            if let firstEpisode {
                leadingEpisode = firstEpisode
                selectedEpisodeID = firstEpisode
            }
        }
    }

    private func episodeShelf(cardWidth: CGFloat) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: CGFloat(layout[.itemSpacing])) {
                ForEach(episodes) { episode in
                    EmbyEpisodeCard(source: source, episode: episode, width: cardWidth,
                                    height: layout.episodeCardHeight, position: resumePosition(episode),
                                    isBusy: busy.contains(episode.id), isSelected: episode.id == selectedEpisodeID,
                                    open: { openedEpisodeID = episode.id },
                                    clear: { clearProgress(for: episode) },
                                    preloadedData: preparedArtwork[episode.id], artworkIsPrepared: detailDataReady,
                                    setPlayed: { played in
                                        playback.setPlayed(played, for: episode.item, source: source) { actionError = $0 }
                                    })
                        .id(episode.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollClipDisabled()
        .contentMargins(.horizontal, CGFloat(layout[.endPadding]), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never, anchor: .leading))
        .scrollPosition(id: $leadingEpisode, anchor: .leading)
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.width > geometry.containerSize.width + 1
                && geometry.contentOffset.x + geometry.containerSize.width >= geometry.contentSize.width - 2
        } action: { _, isAtEnd in
            episodeShelfAtEnd = isAtEnd
        }
        .onScrollPhaseChange { _, phase in
            guard phase == .idle else { return }
            if let target = pendingInitialEpisodeID {
                guard leadingEpisode == target else { return }
                finishInitialEpisodeSelection(target)
            } else {
                commitSelectedEpisode(episodeShelfAtEnd ? episodes.last?.id : leadingEpisode)
            }
        }
        .task(id: episodes.map(\.id)) {
            guard let target = pendingInitialEpisodeID else { return }
            await Task.yield()
            await Task.yield()
            guard !Task.isCancelled else { return }
            leadingEpisode = target
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, pendingInitialEpisodeID == target,
                  leadingEpisode == target else { return }
            finishInitialEpisodeSelection(target)
        }
    }

    @ViewBuilder
    private var similarSection: some View {
        if !similar.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("类似作品").font(.system(size: 17, weight: .semibold)).padding(.horizontal, CGFloat(layout[.endPadding]))
                    .padding(.vertical, CGFloat(layout[.titlePadding]))
                shelf {
                    ForEach(similar) { item in
                        Button { openedRecommendation = item } label: {
                            MediaThumbnail(source: source, item: item, imageOrientation: .portrait,
                                           preloadedData: preparedArtwork[item.id], artworkIsPrepared: detailDataReady)
                                .frame(width: CGFloat(layout[.itemWidth]), height: CGFloat(layout[.itemHeight]))
                                .mediaArtworkBorder()
                                .matchedTransitionSource(id: item.id, in: recommendationZoom)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: item.title))
                        .modifier(MediaThumbnailMenu(source: source, item: item, playback: playback,
                                                     showsEmbyFacts: true, openEmbyDetails: { openedRecommendation = item }) { EmptyView() })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var creditsSection: some View {
        if let credits = metadata?.credits, !credits.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("演职人员").font(.system(size: 17, weight: .semibold)).padding(.horizontal, CGFloat(layout[.endPadding]))
                    .padding(.vertical, CGFloat(layout[.titlePadding]))
                shelf {
                    ForEach(credits) { credit in
                        Button { openedPerson = credit.person } label: {
                            VStack(spacing: 6) {
                                Group {
                                    if let image = credit.image {
                                        MediaThumbnail(source: source, item: image, aspectRatio: 1,
                                                       imageOrientation: .square,
                                                       preloadedData: preparedArtwork[image.id],
                                                       missingArtworkSymbol: "person.crop.circle.fill", artworkIsPrepared: detailDataReady)
                                    } else {
                                        MediaCardBackdrop(showsMissingArtwork: true,
                                                          missingArtworkSymbol: "person.crop.circle.fill")
                                    }
                                }
                                .frame(width: 78, height: 78)
                                .clipShape(Circle())
                                Text(verbatim: credit.person.name).font(.subheadline).lineLimit(1)
                                Text(verbatim: credit.role).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 104)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var linksSection: some View {
        if let links = metadata?.links, !links.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("链接").font(.system(size: 17, weight: .semibold)).padding(.horizontal, CGFloat(layout[.endPadding]))
                    .padding(.vertical, CGFloat(layout[.titlePadding]))
                shelf {
                    ForEach(links) { link in
                        Link(destination: link.url) {
                            Label(link.name, systemImage: "arrow.up.right")
                                .font(.subheadline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(VesperTheme.mediaCardBackground, in: Capsule())
                                .overlay {
                                    Capsule()
                                        .strokeBorder(.primary.opacity(0.18), lineWidth: 1)
                                        .allowsHitTesting(false)
                                }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var seriesInformationSection: some View {
        if series.isEmbySeries, let groups = metadata?.seriesInformation, !groups.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("剧集详细信息").font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: group.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.fields) { field in
                            LabeledContent {
                                Text(verbatim: field.value)
                                    .multilineTextAlignment(.trailing)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            } label: {
                                Text(verbatim: field.label).foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                    }
                    if group.id != groups.last?.id { Divider() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CGFloat(layout[.endPadding]))
        }
    }

    private func shelf<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: CGFloat(layout[.itemSpacing])) { content() }
                .scrollTargetLayout()
                .padding(.vertical, CGFloat(layout[.itemVerticalPadding]))
        }
        .scrollClipDisabled()
        .contentMargins(.horizontal, CGFloat(layout[.endPadding]), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never, anchor: .leading))
        .scrollIndicators(.hidden)
        .padding(.vertical, CGFloat(layout[.scrollPadding]))
    }

    private func resumePosition(_ episode: EmbyEpisode) -> Double {
        max(episode.item.resumePosition ?? 0, playback.savedProgress(for: episode.item))
    }

    private func loadDetail() async {
        let repository = EmbyRepository.shared
        loadError = nil
        detailDataReady = false
        pendingInitialEpisodeID = nil
        preparedArtwork = [:]
        async let info = repository.detailMetadata(for: series, source: source)
        async let recommendations = isEpisode ? nil : try? repository.similarTitles(for: series, source: source)
        if series.isEmbySeries { await loadEpisodes() }
        do {
            let details = try await info
            try Task.checkCancellation()
            metadata = details
            selectedMediaSourceID = series.embyMediaSourceID ?? details.mediaVersions.first?.id
            if let selectedVersion { resetTrackSelection(for: selectedVersion) }
            loadedSeriesID = series.id
        } catch {
            if !Task.isCancelled {
                if !series.isEmbySeries { loadError = error.localizedDescription }
                loadedSeriesID = series.isEmbySeries ? series.id : nil
            }
        }
        let relatedTitles = await recommendations
        if !Task.isCancelled {
            similar = relatedTitles ?? []
            let images = episodes.map { ($0.item, EmbyImageOrientation.landscape) }
                + similar.map { ($0, EmbyImageOrientation.portrait) }
                + (metadata?.credits.compactMap(\.image) ?? []).map { ($0, EmbyImageOrientation.square) }
            preparedArtwork = await prepareDetailArtwork(images)
            guard !Task.isCancelled else { return }
            detailDataReady = true
            if startsWithCarouselInformationHidden {
                await Task.yield()
                guard !Task.isCancelled else { return }
                carouselDetailReady = true
                await Task.yield()
                onCarouselDetailReady?()
            }
        }
    }

    private func prepareDetailArtwork(_ images: [(MediaItem, EmbyImageOrientation)]) async -> [MediaID: Data] {
        let source = source
        return await withTaskGroup(of: (MediaID, Data?).self) { tasks in
            var pending = images.makeIterator()
            func enqueueNext() {
                guard let (item, orientation) = pending.next() else { return }
                tasks.addTask {
                    (item.id, await MediaThumbnailLoader.shared.load(item, source: source, imageOrientation: orientation))
                }
            }
            for _ in 0..<6 { enqueueNext() }
            var result: [MediaID: Data] = [:]
            for await (id, data) in tasks {
                guard !Task.isCancelled else { tasks.cancelAll(); break }
                result[id] = data
                enqueueNext()
            }
            return result
        }
    }

    private func resetTrackSelection(for version: EmbyMediaVersionDetails) {
        selectedAudioIndex = version.defaultAudioStreamIndex
            ?? version.streams.first(where: { $0.type == "Audio" && $0.isDefault })?.id
            ?? version.streams.first(where: { $0.type == "Audio" })?.id
        let subtitleIndex = version.defaultSubtitleStreamIndex
            ?? version.streams.first(where: { $0.type == "Subtitle" && $0.isDefault })?.id
        selectedSubtitleIndex = subtitleIndex.flatMap { $0 >= 0 ? $0 : nil }
    }

    private func clearItemProgress() {
        let target = item
        guard busy.insert(target.id).inserted else { return }
        Task {
            defer { busy.remove(target.id) }
            do {
                try await playback.clearProgress(for: target, source: source)
                clearedServerProgress = true
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func loadEpisodes() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let fetched = try await EmbyRepository.shared.seriesEpisodes(for: series, source: source)
            try Task.checkCancellation()
            episodes = fetched
            seasonNumbers = Array(Set(fetched.map(\.season))).sorted()
            let target = fetched.first(where: shouldResume) ?? fetched.last
            selectedSeason = target?.season ?? seasonNumbers.first
            selectedEpisodeID = nil
            pendingInitialEpisodeID = target?.id
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    private func shouldResume(_ episode: EmbyEpisode) -> Bool {
        let position = resumePosition(episode)
        if position > 0, let duration = episode.item.duration, duration > 0, position < duration * 0.95 {
            return true
        }
        return !playback.effectivePlayed(for: episode.item)
    }

    private func commitSelectedEpisode(_ id: MediaID?) {
        guard let selected = episodes.first(where: { $0.id == id }) ?? episodes.last else { return }
        selectedEpisodeID = selected.id
        if selectedSeason != selected.season { selectedSeason = selected.season }
    }

    private func finishInitialEpisodeSelection(_ id: MediaID) {
        guard let selected = episodes.first(where: { $0.id == id }) else { return }
        selectedEpisodeID = selected.id
        selectedSeason = selected.season
        pendingInitialEpisodeID = nil
    }

    private func playSelectedEpisode() {
        guard let selected = episodes.first(where: { $0.id == selectedEpisodeID }) else { return }
        playback.play(selected.item, in: source, queue: Array(episodes.dropFirst(episodes.firstIndex(where: { $0.id == selected.id }) ?? 0).map(\.item)))
    }

    private func toggleSelectedEpisodePlayed() {
        guard let selected = episodes.first(where: { $0.id == selectedEpisodeID }) else { return }
        let played = playback.effectivePlayed(for: selected.item)
        playback.setPlayed(!played, for: selected.item, source: source) { actionError = $0 }
    }

    private func clearProgress(for episode: EmbyEpisode) {
        guard busy.insert(episode.id).inserted else { return }
        Task {
            defer { busy.remove(episode.id) }
            do {
                try await playback.clearProgress(for: episode.item, source: source,
                                                 syncServer: (episode.item.resumePosition ?? 0) > 0)
                if let index = episodes.firstIndex(where: { $0.id == episode.id }) {
                    episodes[index].item.resumePosition = 0
                }
            } catch { actionError = error.localizedDescription }
        }
    }
}

// Recommendations can show a series recursively, so erase the sheet's view type.
@MainActor
func embyDetailsSheet(source: MediaSource, item: MediaItem, artworkZoom: Namespace.ID) -> AnyView {
    if item.isEmbySeries {
        return AnyView(
            NavigationStack {
                EmbyMediaDetailView(source: source, series: item, showsCloseButton: true)
            }
            .navigationTransition(.zoom(sourceID: item.id, in: artworkZoom))
        )
    }
    return AnyView(
        NavigationStack {
            EmbyMediaDetailView(source: source, series: item, showsCloseButton: true)
        }
    )
}

extension EmbyEpisode {
    var numberLabel: String {
        number.map { String(localized: "第\($0)集") } ?? String(localized: "单集")
    }

    var displayTitle: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? numberLabel : title
    }
}

private struct EmbyEpisodeCard: View {
    let source: MediaSource
    let episode: EmbyEpisode
    let width: CGFloat
    let height: CGFloat
    let position: Double
    let isBusy: Bool
    let isSelected: Bool
    let open: () -> Void
    let clear: () -> Void
    var preloadedData: Data? = nil
    var artworkIsPrepared = false
    let setPlayed: (Bool) -> Void

    @EnvironmentObject private var playback: PlaybackSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedArtwork: EpisodeArtwork?

    private struct EpisodeArtwork {
        let key: String
        let image: UIImage?
        let bottomStrip: UIImage?
    }

    private var artworkKey: String {
        "\(AppCacheStore.embyArtworkKey(for: episode.item, source: source))|landscape"
    }

    private var artwork: EpisodeArtwork? {
        loadedArtwork?.key == artworkKey ? loadedArtwork : nil
    }

    private var title: String { episode.displayTitle }
    private var showsEpisodeNumber: Bool { episode.displayTitle != episode.numberLabel }

    private var artworkHeight: CGFloat {
        guard let image = artwork?.image else { return 0 }
        return width * image.size.height / max(1, image.size.width)
    }

    var body: some View {
        let showsMissingArtwork = artwork != nil && artwork?.image == nil

        MediaCardBackdrop(showsMissingArtwork: showsMissingArtwork, iconCenterY: 1.0 / 3)
        .frame(width: width, height: height)
        .overlay(alignment: .top) {
            if let image = artwork?.image {
                ZStack(alignment: .top) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: width, height: artworkHeight)
                        .frame(width: width, height: height, alignment: .top)
                        .clipped()
                    let blendStart = min(height * 0.38, max(0, artworkHeight - 32))
                    blurredArtwork(height: height - blendStart)
                        .offset(y: blendStart)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) { details }
        .overlay(alignment: .bottomTrailing) { moreButton.padding(.trailing, 10).padding(.bottom, 10) }
        .mediaArtworkBorder(cornerRadius: 16, isSelected: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
        .contextMenu { actions } preview: {
            VStack(alignment: .leading, spacing: 8) {
                MediaCardBackdrop(showsMissingArtwork: showsMissingArtwork)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let image = artwork?.image {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                    }
                    .mediaArtworkBorder()
                if showsEpisodeNumber {
                    Text(verbatim: episode.numberLabel).font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: title).font(.headline).lineLimit(2)
            }
            .frame(width: 280)
            .padding(12)
        }
        .task(id: "\(artworkKey)|\(artworkIsPrepared)") {
            guard artworkIsPrepared else { return }
            let key = artworkKey
            let data = preloadedData
            guard !Task.isCancelled else { return }
            let image = data.flatMap { UIImage(data: $0) }
            let bottomStrip = image.flatMap(\.cgImage).flatMap { cgImage in
                let depth = max(1, cgImage.height / 6)
                return cgImage.cropping(to: CGRect(x: 0, y: cgImage.height - depth,
                                                 width: cgImage.width, height: depth)).map { UIImage(cgImage: $0) }
            }
            loadedArtwork = EpisodeArtwork(key: key, image: image, bottomStrip: bottomStrip)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsEpisodeNumber {
                Text(verbatim: episode.numberLabel).font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Text(verbatim: episode.item.embyPresentation?.overview ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
            playbackRow
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: height * 0.5, alignment: .bottomLeading)
        .offset(y: 4)
    }

    private func blurredArtwork(height: CGFloat) -> some View {
        ZStack {
            if let bottomStrip = artwork?.bottomStrip {
                Image(uiImage: bottomStrip).resizable()
                    .frame(width: width + 44, height: height + 44)
                    .blur(radius: 22)
            }
            (colorScheme == .dark ? Color.black.opacity(0.66) : Color.white.opacity(0.74))
        }
        .frame(width: width, height: height)
        .clipped()
        .mask {
            LinearGradient(colors: [.clear, .black], startPoint: .top,
                           endPoint: UnitPoint(x: 0.5, y: min(1, 45 / max(1, height))))
        }
    }

    private var playbackRow: some View {
        HStack(spacing: 7) {
            MediaPlaybackStatus(position: position, duration: episode.item.duration, played: effectivePlayed)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var moreButton: some View {
        Menu { actions } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多操作")
    }

    @ViewBuilder
    private var actions: some View {
        Button("前往单集", systemImage: "info.circle", action: open)
        if position > 0 {
            Button("清除播放进度", systemImage: "clock.arrow.circlepath", action: clear)
                .disabled(isBusy || ((episode.item.resumePosition ?? 0) > 0 && source.emby?.userID == nil))
        }
        let played = effectivePlayed
        Button(played ? "标记为未观看" : "标记为已观看",
               systemImage: played ? "circle" : "checkmark.circle") {
            setPlayed(!played)
        }
        .disabled(source.emby?.userID == nil)
    }

    private var effectivePlayed: Bool {
        playback.effectivePlayed(for: episode.item)
    }
}
