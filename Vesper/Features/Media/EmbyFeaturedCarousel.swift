import SwiftUI
import UIKit
import Network

struct EmbyFeaturedCarousel: View {
    let source: MediaSource
    let items: [MediaItem]
    let featuredArtwork: [MediaID: EmbyFeaturedArtwork]?
    let isMediaRoot: Bool
    let hidesInformation: Bool
    let openDetail: (EmbyMediaRoute) -> Void
    @EnvironmentObject private var library: SourceLibrary
    @Environment(\.vesperRootHeaderHeight) private var headerHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: MediaID?
    @State private var incoming: MediaID?
    @State private var direction = 1
    @State private var progress = 0.0
    @State private var isDragging = false
    @State private var transitionID: UUID?

    private let mirrorFraction: CGFloat = 0.25
    private let travelFraction: CGFloat = 0.25

    var body: some View {
        let hasPosters = !items.isEmpty

        let pages = GeometryReader { geometry in
            let width = geometry.size.width
            if hasPosters {
                let page = currentIndex
                let isTransitioning = isDragging || transitionID != nil
                ZStack {
                    // Keep adjacent artwork mounted so a pan can reveal it immediately.
                    ForEach(visiblePages(around: page)) { item in
                        let isCurrent = item.id == items[page].id
                        let isIncoming = item.id == incoming
                        let shift = reduceMotion ? 0 : CGFloat(direction) * width * travelFraction
                        let images = featuredArtwork?[item.id]
                        let route = EmbyMediaRoute.detail(source, item, origin: .carousel)
                        Button { openDetail(route) } label: {
                            EmbyFeaturedPage(source: source, item: item, size: geometry.size,
                                             featuredArtwork: images,
                                             featuredArtworkIsPrepared: images != nil,
                                             showsInformation: isCurrent && !isTransitioning && !hidesInformation,
                                             mirroredEdgeFraction: (isCurrent || isIncoming) && isTransitioning && !reduceMotion ? mirrorFraction : 0)
                        }
                        .buttonStyle(EmbyCarouselButtonStyle())
                        .accessibilityLabel(Text(verbatim: item.title))
                        .opacity(isCurrent ? 1 - progress : isIncoming ? progress : 0)
                        .frame(width: width)
                        .offset(x: isCurrent ? -shift * progress : shift * (1 - progress))
                        .padding(.horizontal, width * mirrorFraction)
                        .frame(width: width)
                        .zIndex(isIncoming ? 2 : isCurrent ? 1 : 0)
                        .allowsHitTesting(isCurrent && !isTransitioning)
                        .accessibilityHidden(!isCurrent)
                    }
                }
                .frame(width: width, height: geometry.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(EmbyCarouselPan(enabled: items.count > 1 && transitionID == nil) { state, translation, velocity in
                    handlePan(state, translation: translation, velocity: velocity, width: width)
                })
                .overlay(alignment: .bottom) {
                    if items.count > 1 {
                        EmbyFeaturedPageControl(count: items.count, current: page) { target in
                            guard !isDragging, transitionID == nil, items.indices.contains(target), target != page else { return }
                            let forward = (target - page + items.count) % items.count
                            startTransition(to: target, direction: forward <= items.count - forward ? 1 : -1)
                        }
                        .frame(height: 44)
                        .contentShape(Rectangle())
                        .padding(.bottom, 12)
                        .allowsHitTesting(!isTransitioning)
                    }
                }
                .modifier(EmbyPosterStretch(geometry: geometry))
                .transition(.opacity)
            }
        }

        return EmbyCarouselRevealLayout(headerHeight: headerHeight, progress: hasPosters ? 1 : 0) {
            pages
        }
        .animation(reduceMotion || !hasPosters ? nil : .easeOut(duration: 0.32), value: hasPosters)
        .onChange(of: items.map(\.id), initial: true) { _, ids in
            guard selection.map(ids.contains) != true else { return }
            resetTransition()
            selection = ids.first
        }
        .onDisappear { resetTransition() }
        .task(id: RotationState(selection: selection, enabled: canRotate)) {
            guard canRotate else { return }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard !Task.isCancelled, canRotate else { return }
            startTransition(to: wrappedIndex(currentIndex + 1), direction: 1)
        }
    }

    private var currentIndex: Int { items.firstIndex { $0.id == selection } ?? 0 }

    private func wrappedIndex(_ index: Int) -> Int {
        (index + items.count) % items.count
    }

    private func visiblePages(around page: Int) -> [MediaItem] {
        guard !items.isEmpty else { return [] }
        let neighbors = Set([page, wrappedIndex(page - 1), wrappedIndex(page + 1)])
        return items.enumerated().compactMap { index, item in
            neighbors.contains(index) || item.id == incoming ? item : nil
        }
    }

    private func handlePan(_ state: UIGestureRecognizer.State, translation: CGFloat, velocity: CGFloat, width: CGFloat) {
        guard items.count > 1, transitionID == nil, width > 0 else { return }
        switch state {
        case .began, .changed:
            isDragging = true
            direction = translation <= 0 ? 1 : -1
            incoming = items[wrappedIndex(currentIndex + direction)].id
            progress = min(abs(translation) / width, 1)
        case .ended:
            guard isDragging else { return }
            let projectedDistance = translation + velocity * 0.18
            let advances = abs(translation) >= width * 0.28
                || (abs(projectedDistance) >= width * 0.28 && projectedDistance * translation > 0)
            settle(advances: advances)
        case .cancelled, .failed:
            if isDragging { settle(advances: false) }
        default:
            break
        }
    }

    private func startTransition(to index: Int, direction: Int) {
        guard transitionID == nil, items.indices.contains(index), index != currentIndex else { return }
        self.direction = direction
        incoming = items[index].id
        settle(advances: true)
    }

    private func settle(advances: Bool) {
        let token = UUID()
        let destination = advances ? incoming : nil
        transitionID = token
        isDragging = false
        withAnimation(.easeOut(duration: reduceMotion ? 0.16 : 0.32), completionCriteria: .removed) {
            progress = advances ? 1 : 0
        } completion: {
            guard transitionID == token else { return }
            if let destination { selection = destination }
            resetTransition()
        }
    }

    private func resetTransition() {
        incoming = nil
        progress = 0
        isDragging = false
        transitionID = nil
    }

    private var canRotate: Bool {
        isMediaRoot && items.count > 1 && !isDragging && transitionID == nil && !reduceMotion
            && !voiceOverEnabled && scenePhase == .active
    }

    private struct RotationState: Equatable {
        let selection: MediaID?
        let enabled: Bool
    }
}

/// The compact carousel reserves exactly the root header's height until artwork is ready.
private struct EmbyCarouselRevealLayout: Layout {
    let headerHeight: CGFloat
    nonisolated var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.replacingUnspecifiedDimensions().width
        let width = proposedWidth.isFinite ? proposedWidth : 0
        let posterHeight = width / EmbyPosterLayout.aspectRatio
        let height = headerHeight + (posterHeight - headerHeight) * progress
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.minY),
                              anchor: .top, proposal: ProposedViewSize(bounds.size))
    }
}

private struct EmbyCarouselPan: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let onPan: (UIGestureRecognizer.State, CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        context.coordinator.enabled = enabled
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.enabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        onPan(recognizer.state, recognizer.translation(in: recognizer.view).x,
              recognizer.velocity(in: recognizer.view).x)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var enabled = false

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard enabled, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var touchedView = touch.view
            while let view = touchedView {
                if view is UIControl { return false }
                touchedView = view.superview
            }
            return true
        }
    }
}

enum EmbyPosterLayout {
    static let aspectRatio: CGFloat = 3.0 / 5.0
    static let informationBottomInset: CGFloat = 132
    static let seriesFooterBottomInset: CGFloat = 14
}

struct EmbyPosterStretch: ViewModifier {
    let geometry: GeometryProxy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let pull = max(0, geometry.frame(in: .scrollView(axis: .vertical)).minY)
        let scale = reduceMotion ? 1 : 1 + min(pull / max(geometry.size.height, 1), 0.08)
        content
            .scaleEffect(scale, anchor: .top)
            .frame(width: geometry.size.width, height: geometry.size.height + pull, alignment: .top)
            .clipped()
            .offset(y: -pull)
    }
}

struct CarouselPosterBlur {
    let heightFraction: CGFloat
    let fadeHeight: CGFloat
    let strength: Double
    let tintOpacity: Double
}

struct EmbyFeaturedPage: View {
    let source: MediaSource
    let item: MediaItem
    let size: CGSize
    let featuredArtwork: EmbyFeaturedArtwork?
    let featuredArtworkIsPrepared: Bool
    var initialHeroArtwork: EmbyFeaturedArtwork? = nil
    var crossfadesArtwork = false
    var usesEpisodeArtwork = false
    var episodeContext = ""
    let showsInformation: Bool
    var seriesFooter: EmbySeriesHeroFooter? = nil
    var seriesFooterOpacity: Double = 1
    var mirroredEdgeFraction: CGFloat = 0
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var loadedArtwork: EmbyFeaturedArtwork?
    @State private var loadedArtworkID: MediaID?

    var body: some View {
        let images = featuredArtworkIsPrepared
            ? featuredArtwork
            : loadedArtworkID == item.id ? loadedArtwork : initialHeroArtwork
        Group {
            if usesEpisodeArtwork {
                MediaCardBackdrop(showsMissingArtwork: loadedArtwork != nil && images?.poster == nil, iconCenterY: 1.0 / 3)
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        ZStack {
                            if let data = images?.poster, let image = UIImage(data: data) {
                                EmbyEpisodeArtworkSurface(image: image, size: size)
                                    .id(data.hashValue)
                                    .transition(.opacity)
                            }
                        }
                        .animation(crossfadesArtwork && !reduceMotion ? .easeInOut(duration: 0.3) : nil,
                                   value: images?.poster)
                    }
            } else {
        MediaThumbnail(source: source, item: item, aspectRatio: EmbyPosterLayout.aspectRatio,
                       imageOrientation: usesEpisodeArtwork ? .landscape : .portrait,
                       crossfadesArtwork: crossfadesArtwork, allowsRemotePrimary: false, cornerRadius: 0, fixedHeight: size.height,
                       preloadedData: images?.poster,
                       artworkIsPrepared: images?.poster != nil,
                       mirroredEdgeFraction: mirroredEdgeFraction,
                       showsMissingArtwork: featuredArtworkIsPrepared || loadedArtwork != nil)
            }
        }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    if !usesEpisodeArtwork { bottomBlur }

                    VStack(spacing: 0) {
                        VStack(spacing: 6) {
                            Group {
                                if !usesEpisodeArtwork, let logo = images?.logo, let image = UIImage(data: logo) {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFit()
                                        .accessibilityLabel(Text(verbatim: item.title))
                                } else {
                                    Text(verbatim: item.title)
                                        .font(.largeTitle.weight(.semibold))
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.75)
                                }
                            }
                            .frame(maxWidth: size.width * 0.68)
                            .frame(height: size.height * 0.14)
                            VStack(spacing: 4) {
                                Text(verbatim: usesEpisodeArtwork ? episodeContext : firstLine)
                                if !usesEpisodeArtwork && !secondLine.isEmpty { Text(verbatim: secondLine) }
                            }
                            .font(.subheadline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(height: size.height * 0.06)
                        }
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                        .shadow(color: (colorScheme == .dark ? Color.black : Color.white).opacity(0.65), radius: 3, y: 1)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.bottom, seriesFooter == nil ? EmbyPosterLayout.informationBottomInset : 16)
                        .offset(y: seriesFooter == nil ? -24 : 0)
                        .frame(maxWidth: .infinity)
                        .opacity(showsInformation ? 1 : 0)
                        .animation(.easeInOut(duration: 0.16), value: showsInformation)
                        .accessibilityHidden(true)
                        if let seriesFooter {
                            seriesFooter
                                .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
                                .shadow(color: (colorScheme == .dark ? Color.black : Color.white).opacity(0.65), radius: 3, y: 1)
                                .padding(.horizontal, 20)
                                .padding(.bottom, EmbyPosterLayout.seriesFooterBottomInset)
                                .opacity(seriesFooterOpacity)
                                .accessibilityHidden(seriesFooterOpacity == 0)
                                .allowsHitTesting(seriesFooterOpacity > 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .task(id: item.id) {
                guard !featuredArtworkIsPrepared else { return }
                if loadedArtworkID != item.id {
                    loadedArtwork = nil
                    loadedArtworkID = nil
                }
                let images: EmbyFeaturedArtwork
                if usesEpisodeArtwork {
                    let poster = await MediaThumbnailLoader.shared.load(item, source: source, imageOrientation: .landscape)
                    images = EmbyFeaturedArtwork(poster: poster, logo: nil)
                } else {
                    images = await MediaThumbnailLoader.shared.featuredArtwork(for: item, source: source)
                }
                guard !Task.isCancelled else { return }
                // Keep already-visible artwork if the refresh failed.
                loadedArtwork = EmbyFeaturedArtwork(poster: images.poster ?? initialHeroArtwork?.poster,
                                                     logo: images.logo ?? initialHeroArtwork?.logo)
                loadedArtworkID = item.id
            }
    }

    private var bottomBlur: some View {
        let blur = layout.carouselBlur
        let solidHeight = size.height * blur.heightFraction
        let fadeHeight = min(blur.fadeHeight, max(0, size.height - solidHeight))
        let totalHeight = solidHeight + fadeHeight
        let fadeEnd = totalHeight > 0 ? fadeHeight / totalHeight : 0
        let strength = blur.strength
        let tint = colorScheme == .dark ? Color.black : Color.white

        return Rectangle()
            .fill(.regularMaterial)
            .opacity(strength)
            .overlay(tint.opacity(blur.tintOpacity))
            .mask {
                if fadeEnd > 0 {
                    LinearGradient(stops: blurMaskStops(fadeEnd: fadeEnd), startPoint: .top, endPoint: .bottom)
                } else {
                    Rectangle()
                }
            }
            .frame(height: totalHeight)
            .allowsHitTesting(false)
    }

    private func blurMaskStops(fadeEnd: CGFloat) -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = [
            .init(color: .clear, location: 0),
            .init(color: .black.opacity(0.15625), location: fadeEnd * 0.25),
            .init(color: .black.opacity(0.5), location: fadeEnd * 0.5),
            .init(color: .black.opacity(0.84375), location: fadeEnd * 0.75),
            .init(color: .black, location: fadeEnd)
        ]
        if fadeEnd < 1 { stops.append(.init(color: .black, location: 1)) }
        return stops
    }

    private var firstLine: String {
        let kind: String
        switch item.embyItemType {
        case "Series": kind = VesperLocalization.string("剧集")
        case "Movie": kind = VesperLocalization.string("电影")
        default: kind = VesperLocalization.string("视频")
        }
        let genres = (item.embyPresentation?.genres ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return ([kind] + genres.prefix(3)).joined(separator: " · ")
    }

    private var secondLine: String {
        let metadata = item.embyPresentation
        let year = item.subtitle ?? metadata?.premiereDate.map {
            String(Calendar(identifier: .gregorian).component(.year, from: $0))
        }
        let status: String?
        switch metadata?.status {
        case "Continuing": status = VesperLocalization.string("连载中")
        case "Ended": status = VesperLocalization.string("已完结")
        case "Upcoming": status = VesperLocalization.string("即将播出")
        default: status = metadata?.status
        }
        let score = metadata?.communityRating.flatMap { rating -> String? in
            guard rating > 0 else { return nil }
            return String(format: "%.1f", rating)
        }
        return [year, status, score].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct EmbyFeaturedPageControl: UIViewRepresentable {
    let count: Int
    let current: Int
    let onChange: (Int) -> Void

    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.backgroundStyle = .minimal
        control.allowsContinuousInteraction = false
        control.addTarget(context.coordinator, action: #selector(Coordinator.pageChanged(_:)), for: .valueChanged)
        control.currentPageIndicatorTintColor = .white
        control.pageIndicatorTintColor = UIColor.white.withAlphaComponent(0.65)
        control.preferredCurrentPageIndicatorImage = UIImage(
            systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9)
        )
        return control
    }

    func updateUIView(_ control: UIPageControl, context: Context) {
        context.coordinator.onChange = onChange
        control.numberOfPages = count
        control.currentPage = current
        for index in 0..<count {
            let distance = abs(index - current)
            let size: CGFloat = distance <= 1 ? 7 : distance == 2 ? 5 : 3
            control.setIndicatorImage(
                UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: size)),
                forPage: index
            )
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIPageControl, context: Context) -> CGSize? {
        let size = uiView.size(forNumberOfPages: count)
        return CGSize(width: max(132, size.width), height: 44)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject {
        var onChange: (Int) -> Void

        init(onChange: @escaping (Int) -> Void) { self.onChange = onChange }

        @objc func pageChanged(_ control: UIPageControl) { onChange(control.currentPage) }
    }
}
