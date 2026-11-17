import AVFoundation
@preconcurrency import Photos
@preconcurrency import AVKit
import MediaPlayer
import Combine
import SwiftUI
@preconcurrency import KSPlayer
import UIKit

/// A single app-owned session. Tabs and player presentation never own or reset
/// the decoder. KSPlayer APIs are contained here, outside navigation code.
@MainActor
final class PlaybackSession: NSObject, ObservableObject, KSPlayerLayerDelegate, @preconcurrency AVPictureInPictureControllerDelegate, @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    @Published private(set) var currentItem: MediaItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var videoView: UIView?
    @Published var isPresented = false
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var fillsScreen = false
    @Published private(set) var bufferedTime: TimeInterval = 0
    @Published private(set) var isSeeking = false
    @Published private(set) var audioTracks: [PlaybackTrack] = []
    @Published private(set) var subtitleTracks: [PlaybackTrack] = []
    @Published private(set) var selectedSubtitleID: Int32?
    @Published private(set) var subtitleText = ""
    @Published private(set) var subtitleImage: UIImage?
    @Published private(set) var isMuted = false
    @Published private(set) var isPictureInPicturePossible = false
    @Published private(set) var isPictureInPictureActive = false
    @Published var playbackNotice: String?
    private var pipController: AVPictureInPictureController?
    private var pipSourceIdentity: ObjectIdentifier?
    private var pipObservation: NSKeyValueObservation?
    private var pipPlayerObservation: NSKeyValueObservation?
    private var restorePiPCompletion: ((Bool) -> Void)?
    private var restoringPiP = false
    private var pendingSeek: (time: TimeInterval, resume: Bool)?
    private var seekInFlight = false
    private var seekLanding: (time: Double, deadline: Date)?
    private let subtitleModel = SubtitleModel()
    private var appIsInBackground = false
    private var appIsInactive = false
    private var progressRestored = false
    private var lastProgressSave = Date.distantPast
    private let progressStorageKey = "player.savedProgress"

    override init() {
        super.init()
        KSOptions.canBackgroundPlay = true
        KSOptions.canStartPictureInPictureAutomaticallyFromInline = false
        let savedRate = UserDefaults.standard.float(forKey: "player.playbackRate")
        if [Float(0.5), 0.75, 1, 1.25, 1.5, 2].contains(savedRate) { playbackRate = savedRate }
    }

    private var layer: KSPlayerLayer?
    private var resource: ResolvedPlaybackResource?
    private var request: Task<Void, Never>?
    private var generation = UUID()
    @Published private(set) var queue: [MediaItem] = []
    private var source: MediaSource?
    private var externalFile: IncomingVideo?

    var queueSource: MediaSource? { source }

    var hasNext: Bool {
        guard let currentItem, let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return false }
        return index + 1 < queue.count
    }
    var canControl: Bool { layer != nil && errorMessage == nil }
    var canSeek: Bool { canControl && duration > 0 && layer?.player.seekable == true }

    func play(_ item: MediaItem, in source: MediaSource, queue: [MediaItem]) {
        externalFile = nil
        self.queue = queue
        self.source = source
        isPresented = true
        load(item, source: source)
    }

    func playExternal(_ file: IncomingVideo) {
        externalFile = file
        source = nil
        queue = []
        let item = MediaItem(id: MediaID(sourceID: file.id, localID: file.name),
                             title: file.name, resource: nil)
        isPresented = true
        load(item, source: nil)
    }

    private func load(_ item: MediaItem, source: MediaSource?) {
        request?.cancel()
        generation = UUID()
        let token = generation
        saveProgress()
        tearDownPlayer()
        progressRestored = false
        currentItem = item
        currentTime = 0
        duration = 0
        errorMessage = nil
        isLoading = true
        let savedRate = UserDefaults.standard.float(forKey: "player.playbackRate")
        playbackRate = [Float(0.5), 0.75, 1, 1.25, 1.5, 2].contains(savedRate) ? savedRate : 1
        let external = externalFile
        request = Task { [weak self] in
            do {
                let resolved: ResolvedPlaybackResource
                if let external {
                    resolved = ResolvedPlaybackResource(url: external.url, externalAccess: external.access)
                } else if let source {
                    resolved = try await PlaybackResourceResolver().resolve(item, source: source)
                } else {
                    throw PlaybackFailure.missingFile
                }
                guard let self, !Task.isCancelled, self.generation == token else {
                    resolved.release()
                    return
                }
                self.resource = resolved
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                let options = KSOptions()
                options.startPlayRate = self.playbackRate
                options.isSeekImageSubtitle = true
                options.canStartPictureInPictureAutomaticallyFromInline = false
                let player = KSPlayerLayer(url: resolved.url, isAutoPlay: false, options: options)
                self.layer = player
                player.delegate = self
                self.videoView = player.player.view
                player.player.allowsExternalPlayback = true
                player.player.isMuted = self.isMuted
                player.player.contentMode = self.fillsScreen ? .scaleAspectFill : .scaleAspectFit
                player.play()
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.tearDownPlayer()
                self.isLoading = false
                self.errorMessage = error.localizedDescription
                self.log("加载失败：\(error.localizedDescription)")
            }
        }
    }

    func togglePlayback() {
        guard let layer, errorMessage == nil else { return }
        if isPlaying { layer.pause() } else { layer.play() }
        pipController?.invalidatePlaybackState()
    }

    func pause() { layer?.pause(); pipController?.invalidatePlaybackState() }

    func seek(to time: TimeInterval, resume: Bool? = nil) {
        guard canSeek, time.isFinite else { return }
        let target = min(max(0, time), duration)
        pendingSeek = (target, resume ?? isPlaying)
        seekLanding = (target, Date().addingTimeInterval(3))
        currentTime = target
        isSeeking = true
        performPendingSeek()
    }

    // Coalesce scrub previews: at most one decoder seek is in flight, and the
    // final release target always replaces any older preview waiting behind it.
    private func performPendingSeek() {
        guard !seekInFlight, let next = pendingSeek, let layer else { return }
        pendingSeek = nil
        seekInFlight = true
        let token = generation
        layer.seek(time: next.time, autoPlay: next.resume) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.seekInFlight = false
                if self.pendingSeek != nil { self.performPendingSeek() }
                else {
                    self.currentTime = finished ? next.time : max(0, layer.player.currentPlaybackTime)
                    self.seekLanding = finished ? (next.time, Date().addingTimeInterval(2)) : nil
                    self.isSeeking = false
                    self.updateSubtitles()
                }
            }
        }
    }

    func toggleMute() {
        isMuted.toggle()
        layer?.player.isMuted = isMuted
    }

    func unmute() {
        isMuted = false
        layer?.player.isMuted = false
    }

    func startPictureInPicture() {
        configurePictureInPicture()
        guard let pipController, pipController.isPictureInPicturePossible else {
            playbackNotice = String(localized: "当前视频暂不支持画中画。")
            return
        }
        layer?.player.contentMode = .scaleAspectFit
        // Use AVKit directly. KSPlayer's isPipActive setter also performs its
        // own UIKit navigation/dismissal, which this app deliberately avoids.
        pipController.startPictureInPicture()
    }

    private func configurePictureInPicture() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let engineController = layer?.player.pipController else { return }
        // The engine can replace its controller when its display layer changes.
        // Never allow either controller to take the system's automatic route.
        engineController.canStartPictureInPictureAutomaticallyFromInline = false
        let sourceIdentity: ObjectIdentifier
        let candidate: AVPictureInPictureController?
        var nativePlayer: AVPlayer?
        if let displayLayer = engineController.contentSource?.sampleBufferDisplayLayer {
            sourceIdentity = ObjectIdentifier(displayLayer)
            guard pipSourceIdentity != sourceIdentity else { return }
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
            candidate = AVPictureInPictureController(contentSource: source)
        } else if let playerLayer = engineController.playerLayer {
            sourceIdentity = ObjectIdentifier(playerLayer)
            guard pipSourceIdentity != sourceIdentity else { return }
            candidate = AVPictureInPictureController(playerLayer: playerLayer)
            nativePlayer = playerLayer.player
        } else { return }
        guard let candidate else { return }
        pipController?.delegate = nil
        pipController?.stopPictureInPicture()
        pipObservation = nil
        pipController = candidate
        pipSourceIdentity = sourceIdentity
        pipPlayerObservation = nativePlayer?.observe(\.timeControlStatus, options: [.new]) { [weak self] _, change in
            guard let status = change.newValue else { return }
            Task { @MainActor in
                guard let self, self.pipSourceIdentity == sourceIdentity, self.isPictureInPictureActive,
                      !self.isSeeking, !self.isLoading, let layer = self.layer else { return }
                switch status {
                case .playing:
                    if !self.isPlaying { layer.play(); self.isPlaying = true }
                case .paused:
                    if self.isPlaying { layer.pause(); self.isPlaying = false }
                case .waitingToPlayAtSpecifiedRate: break
                @unknown default: break
                }
            }
        }
        candidate.delegate = self
        candidate.canStartPictureInPictureAutomaticallyFromInline = false
        isPictureInPicturePossible = candidate.isPictureInPicturePossible
        let identity = ObjectIdentifier(candidate)
        pipObservation = candidate.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, change in
            let possible = change.newValue ?? false
            Task { @MainActor in
                guard let self, let current = self.pipController, ObjectIdentifier(current) == identity else { return }
                self.isPictureInPicturePossible = possible
            }
        }
    }

    // Sample-buffer PiP controls must use the same app-owned transport as the
    // full-screen controls. Decoder-only play/pause bypasses KSPlayerLayer.state.
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        guard controller === pipController, let layer else { return }
        if playing { layer.play() } else { layer.pause() }
        isPlaying = playing
        controller.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        duration > 0 ? CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
            : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { !isPlaying }

    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) { }

    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval interval: CMTime) async {
        guard controller === pipController else { return }
        let target = min(duration, max(0, currentTime + interval.seconds))
        seek(to: target)
        for _ in 0..<150 {
            guard isSeeking, controller === pipController, !Task.isCancelled else { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ controller: AVPictureInPictureController) -> Bool { !PlaybackPreferences.backgroundEnabled }

    func playerDidAppear() {
        restoringPiP = false
        if isPictureInPictureActive { pipController?.stopPictureInPicture() }
        let completion = restorePiPCompletion
        restorePiPCompletion = nil
        completion?(true)
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === pipController else { return }
        layer?.player.contentMode = .scaleAspectFit
    }

    private func restoreVideoContentMode() {
        layer?.player.contentMode = fillsScreen ? .scaleAspectFill : .scaleAspectFit
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === pipController else { return }
        guard !(appIsInBackground || appIsInactive) || (PlaybackPreferences.backgroundEnabled && PlaybackPreferences.backgroundMode == "pip") else {
            controller.stopPictureInPicture()
            if !PlaybackPreferences.backgroundEnabled { pause() }
            return
        }
        isPictureInPictureActive = true
        isPresented = false
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard controller === pipController else { return }
        isPictureInPictureActive = false
        restoreVideoContentMode()
        if !restoringPiP && !isPresented && !(appIsInBackground && PlaybackPreferences.backgroundEnabled && PlaybackPreferences.backgroundMode == "audio") { pause() }
        restoringPiP = false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard controller === pipController else { return }
        playbackNotice = error.localizedDescription
        if appIsInBackground { pause() }
        restoreVideoContentMode()
        log("画中画启动失败：\(error.localizedDescription)")
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard controller === pipController else { completionHandler(false); return }
        restoringPiP = true
        if isPresented { completionHandler(true) }
        else { restorePiPCompletion = completionHandler; isPresented = true }
    }

    func refreshPlaybackPreferences() {
        layer?.player.pipController?.canStartPictureInPictureAutomaticallyFromInline = false
        pipController?.canStartPictureInPictureAutomaticallyFromInline = false
        if !(PlaybackPreferences.backgroundEnabled && PlaybackPreferences.backgroundMode == "pip") && appIsInBackground {
            pipController?.stopPictureInPicture()
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .inactive:
            appIsInactive = true
            refreshPlaybackPreferences()
        case .background:
            appIsInBackground = true
            saveProgress()
            if !PlaybackPreferences.backgroundEnabled || PlaybackPreferences.backgroundMode != "pip" { pipController?.stopPictureInPicture() }
            guard isPlaying else { return }
            guard PlaybackPreferences.backgroundEnabled else {
                pipController?.stopPictureInPicture()
                pause()
                return
            }
            if PlaybackPreferences.backgroundMode == "pip" && !isPictureInPictureActive {
                configurePictureInPicture()
                if let pipController, pipController.isPictureInPicturePossible {
                    layer?.player.contentMode = .scaleAspectFit
                    pipController.startPictureInPicture()
                } else {
                    pause()
                    playbackNotice = VesperLocalization.string("当前视频暂不支持画中画。")
                }
            }
        case .active:
            appIsInBackground = false
            appIsInactive = false
        @unknown default: break
        }
    }

    private var progressKey: String? {
        guard externalFile == nil, let id = currentItem?.id else { return nil }
        return id.sourceID.uuidString + ":" + id.localID
    }

    private func saveProgress() {
        guard PlaybackPreferences.remembersProgress, progressRestored, let key = progressKey,
              duration > 0, currentTime.isFinite else { return }
        var values = UserDefaults.standard.dictionary(forKey: progressStorageKey) as? [String: Double] ?? [:]
        if currentTime >= duration - 2 { values.removeValue(forKey: key) }
        else { values[key] = max(0, currentTime) }
        UserDefaults.standard.set(values, forKey: progressStorageKey)
        lastProgressSave = Date()
    }

    func clearSavedProgress() {
        UserDefaults.standard.removeObject(forKey: progressStorageKey)
    }

    private func restoreProgressIfNeeded() {
        guard !progressRestored, canSeek else { return }
        progressRestored = true
        guard PlaybackPreferences.remembersProgress, let key = progressKey,
              let saved = UserDefaults.standard.dictionary(forKey: progressStorageKey)?[key] as? Double,
              saved > 0, saved < duration - 2 else { return }
        seek(to: saved, resume: isPlaying)
    }

    func mediaDetails() async -> PlaybackVideoDetails? {
        guard let resource else { return nil }
        let token = generation
        let url = resource.url
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        var dimensions: String?
        if let track = tracks.first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let transformed = size.applying(transform)
            dimensions = "\(Int(abs(transformed.width).rounded())) × \(Int(abs(transformed.height).rounded()))"
        }
        var technical: [PlaybackDetailField] = []
        for (index, track) in tracks.enumerated() {
            let prefix = "Video \(index + 1)"
            if let size = try? await track.load(.naturalSize), size.height != 0 {
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let display = size.applying(transform)
                let w = Int(abs(display.width).rounded()), h = Int(abs(display.height).rounded())
                func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
                let divisor = max(1, gcd(w, h))
                technical.append(.init(label: "画面比例", value: "\(w / divisor):\(h / divisor)"))
            }
            if let rate = try? await track.load(.nominalFrameRate), rate > 0 { technical.append(.init(label: "帧率", value: String(format: "%.3f fps", rate))) }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 { technical.append(.init(label: "视频码率", value: String(format: "%.2f Mb/s", rate / 1_000_000))) }
            if let descriptions = try? await track.load(.formatDescriptions) {
                for format in descriptions {
                    technical.append(.init(label: "视频编码", value: "\(prefix) · \(Self.codecName(format))"))
                    let extensions = (CMFormatDescriptionGetExtensions(format) as? [String: Any]) ?? [:]
                    for (key, label) in [("ColorPrimaries", "色彩原色"), ("TransferFunction", "传递函数"), ("YCbCrMatrix", "色彩矩阵"), ("BitsPerComponent", "位深")] {
                        if let value = extensions[key] { technical.append(.init(label: label, value: String(describing: value))) }
                    }
                }
            }
        }
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        technical.append(.init(label: "音轨数量", value: String(audioTracks.isEmpty ? (layer?.player.tracks(mediaType: .audio).count ?? 0) : audioTracks.count)))
        for (index, track) in audioTracks.enumerated() {
            let prefix = "Audio \(index + 1)"
            if let language = try? await track.load(.languageCode) { technical.append(.init(label: "音频语言", value: "\(prefix) · \(language)")) }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 { technical.append(.init(label: "音频码率", value: String(format: "%.0f kb/s", rate / 1000))) }
            if let descriptions = try? await track.load(.formatDescriptions) {
                for format in descriptions {
                    technical.append(.init(label: "音频编码", value: "\(prefix) · \(Self.codecName(format))"))
                    if let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                        technical.append(.init(label: "采样率", value: String(format: "%.0f Hz", stream.mSampleRate)))
                        technical.append(.init(label: "声道数", value: String(stream.mChannelsPerFrame)))
                        if stream.mBitsPerChannel > 0 { technical.append(.init(label: "音频位深", value: "\(stream.mBitsPerChannel) bit")) }
                    }
                }
            }
        }
        if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, duration > 0 {
            technical.append(.init(label: "总码率", value: String(format: "%.2f Mb/s", Double(bytes) * 8 / duration / 1_000_000)))
        }
        technical.append(.init(label: "容器格式", value: url.pathExtension.uppercased()))
        // FFmpeg-backed formats may not expose AVAsset tracks. Read the
        // active decoder's public metadata rather than dropping their details.
        if let player = layer?.player {
            if dimensions == nil {
                let size = player.naturalSize
                if size.width > 0 && size.height > 0 { dimensions = "\(Int(size.width)) × \(Int(size.height))" }
            }
            for type in [AVMediaType.video, .audio] where (type == .video ? tracks.isEmpty : audioTracks.isEmpty) {
                for track in player.tracks(mediaType: type) {
                    let video = type == .video
                    if track.bitRate > 0 { technical.append(.init(label: video ? "视频码率" : "音频码率", value: String(format: "%.0f kb/s", Double(track.bitRate) / 1000))) }
                    if track.bitDepth > 0 { technical.append(.init(label: "位深", value: "\(track.bitDepth) bit")) }
                    if video && track.nominalFrameRate > 0 { technical.append(.init(label: "帧率", value: String(format: "%.3f fps", track.nominalFrameRate))) }
                    if let format = track.formatDescription {
                        technical.append(.init(label: video ? "视频编码" : "音频编码", value: Self.codecName(format)))
                        if !video, let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                            technical.append(.init(label: "采样率", value: String(format: "%.0f Hz", stream.mSampleRate)))
                            technical.append(.init(label: "声道数", value: String(stream.mChannelsPerFrame)))
                        }
                    }
                }
            }
        }
        var synopsis: String?
        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata where item.commonKey == .commonKeyDescription {
                if let text = try? await item.load(.stringValue), !text.isEmpty {
                    synopsis = text
                    break
                }
            }
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileName = externalFile?.name ?? (source?.kind == .local ? URL(fileURLWithPath: currentItem?.id.localID ?? "").lastPathComponent : currentItem?.title)
        guard generation == token else { return nil }
        return PlaybackVideoDetails(fileName: fileName ?? "", dimensions: dimensions,
                                    byteCount: values?.fileSize, synopsis: synopsis,
                                    sourceName: source?.name ?? VesperLocalization.string("外部视频"), technical: technical)
    }

    private static func codecName(_ description: CMFormatDescription) -> String {
        let code = CMFormatDescriptionGetMediaSubType(description)
        let bytes: [UInt8] = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? String(code)
    }

    func progress(for item: MediaItem) -> Double {
        if item.id == currentItem?.id { return currentTime }
        let key = item.id.sourceID.uuidString + ":" + item.id.localID
        return UserDefaults.standard.dictionary(forKey: progressStorageKey)?[key] as? Double ?? 0
    }

    func queueInfo(for item: MediaItem) async -> PlaybackQueueInfo {
        guard let source, source.id == item.id.sourceID else { return .init() }
        if source.kind == .photos {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.id.localID], options: nil).firstObject else { return .init() }
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false
            options.deliveryMode = .fastFormat
            let bytes: Int? = await withCheckedContinuation { continuation in
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                    let bytes = (avAsset as? AVURLAsset).flatMap { try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize }
                    continuation.resume(returning: bytes)
                }
            }
            return .init(duration: asset.duration, dimensions: "\(asset.pixelWidth) × \(asset.pixelHeight)", byteCount: bytes)
        }
        guard source.kind == .local, let resource = try? await PlaybackResourceResolver().resolve(item, source: source) else { return .init() }
        defer { resource.release() }
        let asset = AVURLAsset(url: resource.url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        var dimensions: String?
        if let track = tracks.first, let size = try? await track.load(.naturalSize) {
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let size = size.applying(transform)
            dimensions = "\(Int(abs(size.width))) × \(Int(abs(size.height)))"
        }
        let bytes = try? resource.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return .init(duration: duration.isFinite ? duration : 0, dimensions: dimensions, byteCount: bytes)
    }

    func setPlaybackRate(_ rate: Float) {
        guard [Float(0.5), 0.75, 1, 1.25, 1.5, 2].contains(rate) else { return }
        playbackRate = rate
        layer?.player.playbackRate = rate
    }

    func toggleFill() {
        fillsScreen.toggle()
        if !isPictureInPictureActive { restoreVideoContentMode() }
    }

    func playQueued(_ item: MediaItem) {
        guard let source, queue.contains(where: { $0.id == item.id }) else { return }
        load(item, source: source)
    }

    func selectAudio(_ id: Int32) {
        guard let player = layer?.player,
              let track = player.tracks(mediaType: .audio).first(where: { $0.trackID == id }) else { return }
        player.select(track: track)
        refreshTracks()
    }

    func selectSubtitle(_ id: Int32?) {
        guard let player = layer?.player else { return }
        subtitleModel.selectedSubtitleInfo = nil
        if let id, let track = player.tracks(mediaType: .subtitle).first(where: { $0.trackID == id }) {
            player.select(track: track)
            subtitleModel.selectedSubtitleInfo = player.subtitleDataSouce?.infos.first { $0.subtitleID == String(id) }
        } else {
            for track in player.tracks(mediaType: .subtitle) { track.isEnabled = false }
        }
        selectedSubtitleID = id
        updateSubtitles()
        refreshTracks()
    }

    private func refreshTracks() {
        guard let player = layer?.player else { return }
        let audio = player.tracks(mediaType: .audio).map { PlaybackTrack(id: $0.trackID, name: $0.name, isSelected: $0.isEnabled) }
        let subtitles = player.tracks(mediaType: .subtitle).map { PlaybackTrack(id: $0.trackID, name: $0.name, isSelected: $0.trackID == selectedSubtitleID) }
        if audioTracks != audio { audioTracks = audio }
        if subtitleTracks != subtitles { subtitleTracks = subtitles }
    }

    private func updateSubtitles() {
        _ = subtitleModel.subtitle(currentTime: currentTime)
        let text = subtitleModel.parts.compactMap { $0.text?.string }.joined(separator: "\n")
        if subtitleText != text { subtitleText = text }
        let image = subtitleModel.parts.compactMap(\.image).first
        if subtitleImage !== image { subtitleImage = image }
    }

    func next() {
        guard hasNext, let source, let currentItem,
              let index = queue.firstIndex(where: { $0.id == currentItem.id }) else { return }
        load(queue[index + 1], source: source)
    }

    func retry() {
        guard let currentItem else { return }
        load(currentItem, source: source)
    }

    func stop() {
        saveProgress()
        request?.cancel()
        request = nil
        generation = UUID()
        tearDownPlayer()
        currentItem = nil
        source = nil
        externalFile = nil
        queue = []
        currentTime = 0
        duration = 0
        isLoading = false
        errorMessage = nil
        isPresented = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tearDownPlayer() {
        pipController?.delegate = nil
        pipController?.stopPictureInPicture()
        pipObservation = nil
        pipController = nil
        pipSourceIdentity = nil
        pipPlayerObservation = nil
        isPictureInPicturePossible = false
        isPictureInPictureActive = false
        restorePiPCompletion?(false)
        restorePiPCompletion = nil
        restoringPiP = false
        pendingSeek = nil
        seekInFlight = false
        seekLanding = nil
        layer?.delegate = nil
        layer?.stop()
        videoView?.removeFromSuperview()
        videoView = nil
        layer = nil
        resource?.release()
        resource = nil
        subtitleModel.selectedSubtitleInfo = nil
        _ = subtitleModel.subtitle(currentTime: 0)
        subtitleText = ""
        subtitleImage = nil
        selectedSubtitleID = nil
        audioTracks = []
        subtitleTracks = []
        bufferedTime = 0
        isSeeking = false
        isPlaying = false
    }

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard layer === self.layer else { return }
        videoView = layer.player.view
        isPlaying = state.isPlaying
        isLoading = state == .preparing || state == .buffering
        if appIsInBackground && !PlaybackPreferences.backgroundEnabled && state.isPlaying {
            layer.pause()
            return
        }
        if state == .readyToPlay {
            layer.player.playbackRate = playbackRate
            layer.player.contentMode = fillsScreen ? .scaleAspectFill : .scaleAspectFit
            layer.player.allowsExternalPlayback = true
            layer.player.isMuted = isMuted
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyTitle] = currentItem?.title
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            configurePictureInPicture()
            for track in layer.player.tracks(mediaType: .subtitle) { track.isEnabled = false }
        }
        refreshTracks()
        if state == .playedToTheEnd {
            currentTime = duration
            saveProgress()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        log("状态：\(state)")
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard layer === self.layer else { return }
        // Decoder ticks already queued before a preview/final seek must not
        // overwrite the UI target. Resume normal updates once the decoder lands.
        if !isSeeking {
            if let landing = seekLanding {
                if abs(currentTime - landing.time) < 1.5 || Date() >= landing.deadline {
                    seekLanding = nil
                    self.currentTime = currentTime.isFinite ? max(0, currentTime) : 0
                }
            } else { self.currentTime = currentTime.isFinite ? max(0, currentTime) : 0 }
        }
        duration = totalTime.isFinite ? max(0, totalTime) : 0
        if !isSeeking && layer.player.playbackState != .seeking {
            let playing = layer.player.isPlaying
            if isPlaying != playing { isPlaying = playing }
        }
        let playable = layer.player.playableTime
        bufferedTime = playable.isFinite ? min(duration, max(currentTime, playable)) : currentTime
        refreshTracks()
        updateSubtitles()
        configurePictureInPicture()
        restoreProgressIfNeeded()
        if Date().timeIntervalSince(lastProgressSave) >= 5 && !isSeeking { saveProgress() }
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard layer === self.layer else { return }
        isPlaying = false
        isLoading = false
        if let error {
            errorMessage = error.localizedDescription
            UIApplication.shared.isIdleTimerDisabled = false
            log("播放失败：\(error.localizedDescription)")
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}

    private func log(_ message: String) {
        AppLog.runtimeEntries.append("\(ISO8601DateFormatter().string(from: Date())) [Playback] \(message)")
    }
}

struct PlaybackTrack: Identifiable, Equatable {
    let id: Int32
    let name: String
    let isSelected: Bool
}

struct PlaybackVideoDetails: Sendable {
    let fileName: String
    let dimensions: String?
    let byteCount: Int?
    let synopsis: String?
    let sourceName: String
    let technical: [PlaybackDetailField]
}

struct PlaybackDetailField: Sendable {
    let label: String
    let value: String
}

struct PlaybackQueueInfo: Sendable {
    var duration: Double = 0
    var dimensions: String?
    var byteCount: Int?
}
