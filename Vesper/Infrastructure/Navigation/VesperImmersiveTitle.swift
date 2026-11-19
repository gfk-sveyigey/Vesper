import SwiftUI
import UIKit

/// Each root page owns its header state; detail navigation stays native.
struct VesperRootScrollView<Actions: View, Content: View>: View {
    let title: LocalizedStringKey
    private let actions: Actions
    private let content: Content
    private let extendsContentUnderHeader: Bool
    private let showsLoading: Bool
    private let usesMediaScrollEdges: Bool
    private let scrollPosition: Binding<ScrollPosition>?
    private let onVerticalScrollPhaseChange: (ScrollPhase, CGFloat) -> Void
    private let onVerticalOffsetChange: (CGFloat) -> Void
    private let onTopPullChange: (CGFloat) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.vesperWindowTopInset) private var topInset
    @ScaledMetric(relativeTo: .largeTitle) private var headerContentHeight: CGFloat = 60
    @ScaledMetric(relativeTo: .largeTitle) private var mediaTitleScale: CGFloat = 1
    @ObservedObject private var layout = MediaLayoutSettings.shared
    @State private var mediaHeaderPosition: CGFloat = 0
    @State private var mediaHeaderRest: CGFloat = 0
    @State private var mediaHeaderScroll: MediaHeaderScroll?
    @State private var mediaScrollTrackingOffset: CGFloat?
    @State private var mediaHeaderSnap: MediaHeaderSnap?
    @ScaledMetric(relativeTo: .largeTitle) private var titleLineHeight: CGFloat = 41
    @State private var scrollOffset: CGFloat = 0
    @State private var isInteracting = false
    @State private var headerOffset: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var isSystemScrolling = false
    @State private var isCollapsed = false
    @State private var isSnapping = false
    @State private var animationGeneration = 0
    @State private var contentFitsViewport = true
    @State private var interactionStartOffset: CGFloat = 0
    @State private var interactionStartHeaderOffset: CGFloat = 0
    @State private var interactionStartedCollapsed = false

    init(title: LocalizedStringKey, extendsContentUnderHeader: Bool = false, showsLoading: Bool = false,
         usesMediaScrollEdges: Bool = false,
         scrollPosition: Binding<ScrollPosition>? = nil,
         onVerticalOffsetChange: @escaping (CGFloat) -> Void = { _ in },
         onVerticalScrollPhaseChange: @escaping (ScrollPhase, CGFloat) -> Void = { _, _ in },
         onTopPullChange: @escaping (CGFloat) -> Void = { _ in },
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.extendsContentUnderHeader = extendsContentUnderHeader
        self.showsLoading = showsLoading
        self.usesMediaScrollEdges = usesMediaScrollEdges
        self.scrollPosition = scrollPosition
        self.onVerticalScrollPhaseChange = onVerticalScrollPhaseChange
        self.onVerticalOffsetChange = onVerticalOffsetChange
        self.onTopPullChange = onTopPullChange
        self.content = content()
        self.actions = actions()
    }

    private var animation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.88)
    }

    private var headerHeight: CGFloat {
        headerContentHeight + topInset
    }

    private var contentReachesTitleOffset: CGFloat {
        headerContentHeight - max(0, (headerContentHeight - titleLineHeight) / 2)
    }

    @ViewBuilder
    private var positionedScrollView: some View {
        if let scrollPosition {
            verticalScrollView.scrollPosition(scrollPosition)
        } else {
            verticalScrollView
        }
    }

    private var verticalScrollView: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !extendsContentUnderHeader {
                    Color.clear.frame(height: headerHeight)
                        .accessibilityHidden(true)
                }
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 20)
                    .environment(\.vesperRootHeaderHeight, headerHeight)
                    .environment(\.vesperEmptyContentHeight, max(0, viewportHeight - headerHeight - 20))
            }
            .frame(minHeight: viewportHeight, alignment: .top)
        }
        .scrollDisabled(showsLoading)
        .scrollClipDisabled()
        .scrollBounceBehavior(.always, axes: .vertical)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if isInteracting, scrollOffset <= 1, value.translation.height > 0 {
                        onTopPullChange(value.translation.height)
                    }
                }
        )
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(geometry: geometry, includesTopInset: usesMediaScrollEdges)
        } action: { _, metrics in
            viewportHeight = metrics.viewportHeight
            contentFitsViewport = metrics.contentHeight <= metrics.viewportHeight + 1
            scrollOffset = max(0, metrics.offset)
            if usesMediaScrollEdges {
                if contentFitsViewport {
                    mediaHeaderScroll = nil
                    mediaScrollTrackingOffset = nil
                    if mediaHeaderPosition != 0 || mediaHeaderSnap != nil {
                        settleMediaHeader(at: 0)
                    }
                } else if mediaHeaderScroll != nil {
                    updateMediaHeaderScroll(at: metrics.headerOffset)
                } else {
                    restoreMediaHeaderAfterScrollToTop(offset: metrics.offset)
                }
            } else {
                updateHeader(at: scrollOffset)
            }
            onVerticalOffsetChange(metrics.offset)
        }
        .onScrollPhaseChange { oldPhase, newPhase, context in
            let offset = context.geometry.contentOffset.y + context.geometry.contentInsets.top
            if usesMediaScrollEdges {
                let metrics = ScrollMetrics(geometry: context.geometry, includesTopInset: true)
                updateMediaHeaderPhase(to: newPhase, offset: metrics.headerOffset)
            } else {
                updateLegacyHeaderPhase(from: oldPhase, to: newPhase)
            }
            onVerticalScrollPhaseChange(newPhase, offset)
        }
    }

    private func updateMediaHeaderPhase(to phase: ScrollPhase, offset: CGFloat) {
        isInteracting = phase == .interacting
        guard !contentFitsViewport else {
            mediaScrollTrackingOffset = nil
            return
        }
        switch phase {
        case .tracking:
            finishMediaHeaderScroll(at: offset)
            mediaScrollTrackingOffset = offset
        case .interacting, .animating:
            if mediaHeaderScroll == nil || phase == .animating {
                let position = mediaHeaderSnap?.position(at: .now) ?? mediaHeaderPosition
                mediaHeaderPosition = position
                mediaHeaderSnap = nil
                let start = phase == .interacting ? mediaScrollTrackingOffset ?? offset : offset
                mediaHeaderScroll = MediaHeaderScroll(startOffset: max(0, start),
                                                     initialPosition: position, rest: mediaHeaderRest)
            }
            mediaScrollTrackingOffset = nil
            updateMediaHeaderScroll(at: offset)
        case .decelerating:
            updateMediaHeaderScroll(at: offset)
        case .idle:
            finishMediaHeaderScroll(at: offset)
            mediaScrollTrackingOffset = nil
            restoreMediaHeaderAfterScrollToTop(offset: offset)
        @unknown default:
            finishMediaHeaderScroll(at: offset)
            mediaScrollTrackingOffset = nil
        }
    }

    private func updateLegacyHeaderPhase(from oldPhase: ScrollPhase, to newPhase: ScrollPhase) {
        if newPhase == .animating {
            isSystemScrolling = true
            isInteracting = false
        } else if newPhase == .interacting {
            // A new drag can interrupt either snap direction.
            animationGeneration += 1
            isSnapping = false
            isInteracting = true
            isSystemScrolling = false
            interactionStartOffset = scrollOffset
            interactionStartHeaderOffset = headerOffset
            interactionStartedCollapsed = isCollapsed
        }

        if oldPhase == .interacting, newPhase != .interacting {
            isInteracting = false
            if contentFitsViewport || scrollOffset <= 0.5 {
                expandHeader()
            } else if !isSystemScrolling {
                if interactionStartedCollapsed {
                    // No distance/velocity shortcut can bypass the top gate.
                    settleHeader(collapsed: true)
                } else {
                    settleHeader(collapsed: headerOffset >= snapThreshold
                        || scrollOffset > contentReachesTitleOffset)
                }
            }
        }
        if newPhase == .idle { isSystemScrolling = false }
    }

    var body: some View {
        ZStack(alignment: .top) {
            positionedScrollView
                .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                .scrollEdgeEffectHidden(true, for: .top)
                .scrollEdgeEffectHidden(usesMediaScrollEdges, for: .bottom)
                .ignoresSafeArea(.container, edges: .top)

            if showsLoading {
                VesperPageLoadingOverlay()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                    .zIndex(1)
            }

        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsLoading)
        .task(id: mediaHeaderSnap) {
            guard let snap = mediaHeaderSnap else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, snap.end.timeIntervalSinceNow)))
            } catch { return }
            guard mediaHeaderSnap == snap else { return }
            settleMediaHeader(at: snap.target)
        }
        .preference(key: VesperRootHeaderKey.self, value: rootHeaderPresentation)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Root tabs show their title in the custom header.
                Color.clear
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    private var rootHeaderPresentation: VesperRootHeaderPresentation? {
        if usesMediaScrollEdges {
            return VesperRootHeaderPresentation(header: AnyView(mediaHeader), showsStatusBarBlur: false)
        }
        return VesperRootHeaderPresentation(
            header: AnyView(header),
            showsStatusBarBlur: !contentFitsViewport && isCollapsed
        )
    }

    private var mediaHeader: some View {
        TimelineView(.animation(paused: mediaHeaderSnap == nil)) { timeline in
            let position = mediaHeaderSnap?.position(at: timeline.date) ?? mediaHeaderPosition
            let isCollapsed = position >= 1
            let showsBackdrop = !contentFitsViewport && !isCollapsed && (position > 0 || scrollOffset > 0)

            ZStack(alignment: .top) {
                headerContent
                    .compositingGroup()
                    .blur(radius: CGFloat(layout[.headerForegroundBlur]) * position)
                    .opacity(1 - Double(position))
                    .background {
                        mediaBackdropBlur(
                            isVisible: showsBackdrop,
                            hideDelay: !showsBackdrop && position == 0 ? 0.18 : 0
                        )
                    }
                    // Clip both blur layers in the header's local bounds before moving it.
                    .clipped()
                    .offset(y: -headerContentHeight * position)
                    // Keep visible controls live during the settling animation.
                    .allowsHitTesting(!isCollapsed)
                    .accessibilityHidden(isCollapsed)

                VesperMediaStatusBarBlur(isVisible: isCollapsed)
            }
            .clipped()
        }
    }

    private func mediaBackdropBlur(isVisible: Bool, hideDelay: TimeInterval) -> some View {
        VesperFadingBackdropBlur(style: .systemMaterial,
                                 strength: Double(layout[.headerBackdropBlur]) / 100,
                                 visibility: isVisible ? 1 : 0,
                                 fadesAtBottom: false)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16).delay(hideDelay), value: isVisible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func restoreMediaHeaderAfterScrollToTop(offset: CGFloat) {
        guard !isInteracting, abs(offset) <= 0.5,
              let position = scrollPosition?.wrappedValue,
              !position.isPositionedByUser, position.edge == .top else { return }
        settleMediaHeader(at: 0)
    }

    private func updateMediaHeaderScroll(at offset: CGFloat) {
        guard var scroll = mediaHeaderScroll else { return }
        mediaHeaderPosition = scroll.position(at: offset, height: headerContentHeight)
        mediaHeaderScroll = scroll
    }

    private func finishMediaHeaderScroll(at offset: CGFloat) {
        guard mediaHeaderScroll != nil else { return }
        updateMediaHeaderScroll(at: offset)
        guard let scroll = mediaHeaderScroll else { return }
        mediaHeaderScroll = nil
        snapMediaHeader(to: scroll.destination(at: offset, height: headerContentHeight,
                                                minimumDistance: CGFloat(layout[.headerAnimationMinimumDistance])))
    }

    private func snapMediaHeader(to target: CGFloat) {
        guard !reduceMotion, mediaHeaderPosition != target else {
            settleMediaHeader(at: target)
            return
        }
        mediaHeaderSnap = MediaHeaderSnap(start: .now, initial: mediaHeaderPosition, target: target)
    }

    private func settleMediaHeader(at position: CGFloat) {
        mediaHeaderPosition = position
        mediaHeaderRest = position
        mediaHeaderSnap = nil
    }

    private struct MediaHeaderScroll {
        let startOffset: CGFloat
        private let initialPosition: CGFloat
        private let rest: CGFloat
        private var pulledPastTop = false

        init(startOffset: CGFloat, initialPosition: CGFloat, rest: CGFloat) {
            self.startOffset = startOffset
            self.initialPosition = initialPosition
            self.rest = rest
        }

        mutating func position(at offset: CGFloat, height: CGFloat) -> CGFloat {
            // Keep the header open while the scroll view rebounds from a top pull.
            if offset < 0 { pulledPastTop = true }
            if pulledPastTop { return 0 }

            let height = max(height, 1)
            let endOffset = max(0, offset)
            // An upward scroll starting deeper in the page can still drive collapse.
            // Downward movement at that depth waits until it enters the header-height band.
            let movement: CGFloat
            if startOffset >= height, endOffset > startOffset {
                movement = endOffset - startOffset
            } else {
                movement = min(height, endOffset) - min(height, startOffset)
            }
            return min(1, max(0, initialPosition + movement / height))
        }

        func destination(at offset: CGFloat, height: CGFloat, minimumDistance: CGFloat) -> CGFloat {
            if pulledPastTop { return 0 }

            let endOffset = max(0, offset)
            // Use the scroll view's offset delta, including deceleration.
            let distance = endOffset - startOffset
            if distance > 0 {
                if initialPosition == 1 || endOffset >= height { return 1 }
                return distance < minimumDistance ? 0 : 1
            }
            if distance < 0, endOffset < height {
                if initialPosition == 0 { return 0 }
                return -distance < minimumDistance ? 1 : 0
            }
            return rest
        }
    }

    private struct MediaHeaderSnap: Equatable {
        let start: Date
        let initial: CGFloat
        let target: CGFloat
        private var duration: TimeInterval { target == 0 ? 0.36 : 0.22 }

        var end: Date { start.addingTimeInterval(duration) }

        func position(at date: Date) -> CGFloat {
            let elapsed = CGFloat(date.timeIntervalSince(start) / duration)
            let fraction = min(1, max(0, elapsed))
            if fraction == 1 { return target }
            let progress = 1 - pow(1 - fraction, 3)
            return initial + (target - initial) * progress
        }
    }

    private var snapThreshold: CGFloat { headerHeight * 0.1125 }

    private var headerProgress: CGFloat {
        // The lower edge reaches the status bar's lower edge after travelling
        // just the content-row height (the safe-area inset is not fade travel).
        min(1, max(0, headerOffset / max(headerContentHeight, 1)))
    }

    private var headerTitleFont: Font {
        if usesMediaScrollEdges {
            return .system(size: CGFloat(layout[.headerTitleSize]) * mediaTitleScale, weight: .bold)
        }
        return .largeTitle.bold()
    }

    private var headerContent: some View {
        HStack(spacing: 16) {
            Text(title)
                .font(headerTitleFont)
                .foregroundStyle(Color("VesperPrimaryText"))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            actions
        }
        .padding(.horizontal, 20)
        .frame(height: headerContentHeight)
        .padding(.top, topInset)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        headerContent
        .modifier(VesperHeaderMotionEffect(
            displacement: headerOffset,
            fadeDistance: headerContentHeight,
            reducesMotion: reduceMotion
        ))
        .allowsHitTesting(headerProgress < 1 && !isSnapping)
        .accessibilityHidden(headerProgress >= 1)
    }

    private func updateHeader(at offset: CGFloat) {
        if contentFitsViewport {
            if headerOffset > 0 || isCollapsed || isSnapping { expandHeader() }
            return
        }
        if offset <= 0.5 {
            if headerOffset > 0 || isCollapsed || isSnapping { expandHeader() }
            return
        }
        guard !isSystemScrolling, !isSnapping, isInteracting else { return }
        let distance = offset - interactionStartOffset
        if interactionStartedCollapsed {
            // Content begins below the header's default lower edge only at
            // offset zero. Keep the header hidden until that edge is reached.
            return
        } else {
            // An expanded header follows the drag. Small movements settle
            // back unless the content crossed the mandatory-collapse edge.
            headerOffset = min(headerHeight, max(0, interactionStartHeaderOffset + distance))
        }
    }

    private func expandHeader() {
        animationGeneration += 1
        isSnapping = false
        isCollapsed = false
        withAnimation(animation) { headerOffset = 0 }
    }

    private func settleHeader(collapsed: Bool) {
        guard !isSnapping else { return }
        isSnapping = true
        isCollapsed = collapsed
        animationGeneration += 1
        let generation = animationGeneration
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            headerOffset = collapsed ? headerHeight : 0
        } completion: {
            guard generation == animationGeneration else { return }
            isSnapping = false
        }
    }

    private struct ScrollMetrics: Equatable {
        let offset: CGFloat
        let viewportHeight: CGFloat
        let contentHeight: CGFloat

        init(geometry: ScrollGeometry, includesTopInset: Bool) {
            let topInset = geometry.contentInsets.top
            offset = geometry.contentOffset.y + topInset
            viewportHeight = max(0, geometry.containerSize.height - geometry.contentInsets.bottom
                                 - (includesTopInset ? topInset : 0))
            contentHeight = geometry.contentSize.height
        }

        var headerOffset: CGFloat {
            // Preserve top pull-to-expand, but exclude bottom overscroll from the distance.
            min(offset, max(0, contentHeight - viewportHeight))
        }
    }

}

/// One interpolated position drives all header effects. Independently animating
/// a clamped blur/opacity target would spread the fade over the entire snap
/// distance, making the blur appear detached from the moving header.
private struct VesperHeaderMotionEffect: AnimatableModifier {
    nonisolated var displacement: CGFloat
    let fadeDistance: CGFloat
    let reducesMotion: Bool

    nonisolated var animatableData: CGFloat {
        get { displacement }
        set { displacement = newValue }
    }

    func body(content: Content) -> some View {
        let progress = min(1, max(0, displacement / max(fadeDistance, 1)))
        content
            // Treat the header's foreground as one composited effect group,
            // not a screen-sized backdrop or a separate stationary blur layer.
            .compositingGroup()
            .blur(radius: 8 * progress, opaque: false)
            .clipped()
            .opacity(1 - progress)
            .offset(y: reducesMotion ? 0 : -displacement)
    }
}

extension VesperRootScrollView where Actions == EmptyView {
    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(title: title, content: content) { EmptyView() }
    }
}

private struct VesperRootHeaderHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct VesperWindowTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var vesperRootHeaderHeight: CGFloat {
        get { self[VesperRootHeaderHeightKey.self] }
        set { self[VesperRootHeaderHeightKey.self] = newValue }
    }

    var vesperWindowTopInset: CGFloat {
        get { self[VesperWindowTopInsetKey.self] }
        set { self[VesperWindowTopInsetKey.self] = newValue }
    }
}

/// Lift the root Header above the entire navigation stack without changing
/// UIKit hit-testing, navigation bar visibility, or tab interactions.
private struct VesperRootHeaderPresentation {
    let header: AnyView
    let showsStatusBarBlur: Bool
}

private struct VesperRootHeaderKey: PreferenceKey {
    static var defaultValue: VesperRootHeaderPresentation? { nil }

    static func reduce(value: inout VesperRootHeaderPresentation?, nextValue: () -> VesperRootHeaderPresentation?) {
        if let next = nextValue() { value = next }
    }
}

struct VesperNavigationHeaderLayer: ViewModifier {
    let isRoot: Bool
    @Environment(\.vesperWindowTopInset) private var topInset

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(VesperRootHeaderKey.self, alignment: .top) { presentation in
            if isRoot, let presentation {
                ZStack(alignment: .top) {
                    presentation.header
                    // A graded backdrop blur, with no material card/fill.
                    // Its lower edge fades to clear inside the status bar.
                    VesperBackdropBlur(style: .regular, strength: 1, fadesAtBottom: true)
                        .frame(height: max(0, topInset))
                        .clipped()
                        .opacity(presentation.showsStatusBarBlur ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .ignoresSafeArea(.container, edges: .top)
            }
        }
    }
}

struct VesperMediaStatusBarBlur: View {
    let isVisible: Bool

    @Environment(\.vesperWindowTopInset) private var topInset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var layout = MediaLayoutSettings.shared

    var body: some View {
        if topInset > 0 {
            VesperFadingBackdropBlur(style: .regular,
                                     strength: Double(layout[.statusBarEdgeBlur]) / 100,
                                     visibility: isVisible ? 1 : 0,
                                     fadesAtBottom: true)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isVisible)
                .frame(height: topInset)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Keep the backdrop mounted and interpolate the UIKit blur strength as visibility changes.
private struct VesperFadingBackdropBlur: View, Animatable {
    let style: UIBlurEffect.Style
    let strength: Double
    nonisolated var visibility: Double
    let fadesAtBottom: Bool

    nonisolated var animatableData: Double {
        get { visibility }
        set { visibility = newValue }
    }

    var body: some View {
        VesperBackdropBlur(style: style, strength: strength * visibility, fadesAtBottom: fadesAtBottom)
    }
}

/// A paused UIKit effect transition provides a public blur-strength control.
private struct VesperBackdropBlur: UIViewRepresentable {
    let style: UIBlurEffect.Style
    let strength: Double
    var fadesAtBottom = false

    func makeUIView(context: Context) -> BackdropView {
        BackdropView(style: style, fadesAtBottom: fadesAtBottom)
    }

    func updateUIView(_ view: BackdropView, context: Context) {
        view.setStrength(strength)
    }

    final class BackdropView: UIVisualEffectView {
        private let blur: UIBlurEffect
        private let edgeMask: GradientMask?
        private var animator: UIViewPropertyAnimator?
        private var strength: Double?

        init(style: UIBlurEffect.Style, fadesAtBottom: Bool) {
            blur = UIBlurEffect(style: style)
            edgeMask = fadesAtBottom ? GradientMask() : nil
            super.init(effect: nil)
            isUserInteractionEnabled = false
            clipsToBounds = true
            mask = edgeMask
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func setStrength(_ value: Double) {
            let value = min(1, max(0, value))
            guard strength != value else { return }
            strength = value
            if value == 0 || value == 1 {
                animator?.stopAnimation(true)
                animator = nil
                effect = value == 0 ? nil : blur
                return
            }
            if animator == nil {
                effect = nil
                let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
                    guard let self else { return }
                    self.effect = self.blur
                }
                animator.pausesOnCompletion = true
                animator.startAnimation()
                animator.pauseAnimation()
                self.animator = animator
            }
            animator?.fractionComplete = value
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let edgeMask, edgeMask.frame != bounds else { return }
            edgeMask.frame = bounds
            mask = edgeMask
        }
    }

    private final class GradientMask: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }

        init() {
            super.init(frame: .zero)
            let gradient = layer as! CAGradientLayer
            gradient.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
            gradient.locations = [0, 0.55, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}

struct VesperPageLoadingOverlay: View {
    var body: some View {
        VesperTheme.background
            .overlay { ProgressView().controlSize(.large).accessibilityLabel("正在加载") }
            .accessibilityAddTraits(.isModal)
    }
}

private struct VesperEmptyContentHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 420
}

extension EnvironmentValues {
    var vesperEmptyContentHeight: CGFloat {
        get { self[VesperEmptyContentHeightKey.self] }
        set { self[VesperEmptyContentHeightKey.self] = newValue }
    }
}

struct VesperCenteredEmptyContent: View {
    let message: LocalizedStringKey
    let symbol: String
    @Environment(\.vesperEmptyContentHeight) private var height
    var body: some View {
        VesperEmptyContent(message: message, symbol: symbol)
            .frame(maxWidth: .infinity, minHeight: height)
    }
}
