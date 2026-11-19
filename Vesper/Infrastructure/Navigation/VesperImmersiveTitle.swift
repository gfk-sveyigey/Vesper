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
    @GestureState private var mediaDragActive = false
    @State private var mediaHeaderDrag: MediaHeaderDrag?
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
         usesMediaScrollEdges: Bool = false, scrollPosition: Binding<ScrollPosition>? = nil,
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
                    .environment(\.vesperEmptyContentHeight, max(0, viewportHeight - headerHeight - 20))
            }
            .frame(minHeight: viewportHeight, alignment: .top)
        }
        .scrollDisabled(showsLoading)
        .scrollClipDisabled()
        .scrollBounceBehavior(.always, axes: .vertical)
        .simultaneousGesture(
            DragGesture(minimumDistance: min(4, mediaHeaderMinimumDistance))
                .updating($mediaDragActive) { _, active, _ in
                    if usesMediaScrollEdges { active = true }
                }
                .onChanged { value in
                    let translation = value.translation
                    if usesMediaScrollEdges, !showsLoading {
                        trackMediaHeaderDrag(translation)
                    }
                    if isInteracting, scrollOffset <= 1, translation.height > 0 {
                        onTopPullChange(translation.height)
                    }
                }
                .onEnded { value in
                    guard mediaHeaderDrag != nil else { return }
                    trackMediaHeaderDrag(value.translation)
                    finishMediaHeaderDrag()
                }
        )
        .onChange(of: mediaDragActive) { _, active in
            // A system-cancelled gesture has no onEnded callback.
            if !active, mediaHeaderDrag != nil {
                mediaHeaderDrag = nil
                snapMediaHeader(to: mediaHeaderRest)
            }
        }
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                offset: geometry.contentOffset.y + geometry.contentInsets.top,
                viewportHeight: max(0, geometry.containerSize.height - geometry.contentInsets.bottom),
                contentHeight: geometry.contentSize.height
            )
        } action: { _, metrics in
            viewportHeight = metrics.viewportHeight
            contentFitsViewport = metrics.contentHeight <= metrics.viewportHeight + 1
            scrollOffset = max(0, metrics.offset)
            if usesMediaScrollEdges {
                restoreMediaHeaderAfterScrollToTop(offset: metrics.offset)
            } else {
                updateHeader(at: scrollOffset)
            }
            onVerticalOffsetChange(metrics.offset)
        }
        .onScrollPhaseChange { oldPhase, newPhase, context in
            if usesMediaScrollEdges {
                isInteracting = newPhase == .interacting
                if newPhase == .idle {
                    restoreMediaHeaderAfterScrollToTop(
                        offset: context.geometry.contentOffset.y + context.geometry.contentInsets.top
                    )
                }
            } else {
                updateLegacyHeaderPhase(from: oldPhase, to: newPhase)
            }
            onVerticalScrollPhaseChange(newPhase, context.geometry.contentOffset.y + context.geometry.contentInsets.top)
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
        positionedScrollView
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .scrollEdgeEffectHidden(true, for: .top)
        .scrollEdgeEffectHidden(usesMediaScrollEdges, for: .bottom)
        .overlay(alignment: .top) {
            if usesMediaScrollEdges {
                mediaHeader
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .task(id: mediaHeaderSnap) {
            guard let snap = mediaHeaderSnap else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, snap.end.timeIntervalSinceNow)))
            } catch { return }
            guard mediaHeaderSnap == snap else { return }
            settleMediaHeader(at: snap.target)
        }
        .preference(key: VesperRootHeaderKey.self, value: usesMediaScrollEdges ? nil : VesperRootHeaderPresentation(
            header: AnyView(header),
            showsStatusBarBlur: !contentFitsViewport && isCollapsed
        ))
        .overlay(alignment: .top) {
            Group {
                if showsLoading {
                    VesperPageLoadingOverlay()
                        .ignoresSafeArea(.container, edges: [.top, .bottom])
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsLoading)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        // Keep the empty system bar out of the media root experiment.
        // Pushed pages retain their own system navigation bar settings.
        .toolbarVisibility(usesMediaScrollEdges ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }

    private var mediaHeaderMinimumDistance: CGFloat {
        usesMediaScrollEdges ? CGFloat(layout[.headerAnimationMinimumDistance]) : 4
    }

    private var mediaHeader: some View {
        TimelineView(.animation(paused: mediaHeaderSnap == nil)) { timeline in
            let position = mediaHeaderSnap?.position(at: timeline.date) ?? mediaHeaderPosition
            let isCollapsed = position >= 1
            let showsBackdrop = !isCollapsed && (position > 0 || scrollOffset > 0.5)

            ZStack(alignment: .top) {
                headerContent
                    .compositingGroup()
                    .blur(radius: CGFloat(layout[.headerForegroundBlur]) * position)
                    .opacity(1 - Double(position))
                    .background {
                        if showsBackdrop {
                            VesperBackdropBlur(style: .regular,
                                               strength: Double(layout[.headerBackdropBlur]) / 100)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    // Clip both blur layers in the header's local bounds before moving it.
                    .clipped()
                    .offset(y: -headerContentHeight * position)
                    .allowsHitTesting(!isCollapsed && mediaHeaderSnap == nil)
                    .accessibilityHidden(isCollapsed)

                if isCollapsed, topInset > 0 {
                    VesperBackdropBlur(style: .regular,
                                       strength: Double(layout[.statusBarEdgeBlur]) / 100,
                                       fadesAtBottom: true)
                        .frame(height: topInset)
                        .clipped()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .clipped()
        }
    }

    private func restoreMediaHeaderAfterScrollToTop(offset: CGFloat) {
        guard mediaHeaderDrag == nil, !isInteracting, abs(offset) <= 0.5,
              let position = scrollPosition?.wrappedValue,
              !position.isPositionedByUser, position.edge == .top else { return }
        settleMediaHeader(at: 0)
    }

    private func trackMediaHeaderDrag(_ translation: CGSize) {
        if mediaHeaderDrag == nil {
            guard abs(translation.height) > abs(translation.width) else { return }
            let now = Date.now
            let position = mediaHeaderSnap?.position(at: now) ?? mediaHeaderPosition
            if position == 0 || position == 1 {
                mediaHeaderRest = position
            }
            mediaHeaderPosition = position
            mediaHeaderSnap = nil
            mediaHeaderDrag = MediaHeaderDrag(origin: mediaHeaderRest)
        }
        guard var drag = mediaHeaderDrag else { return }

        mediaHeaderPosition = drag.move(to: translation.height, from: mediaHeaderPosition,
                                            travel: headerContentHeight)
        mediaHeaderDrag = drag
        if mediaHeaderPosition == 0 || mediaHeaderPosition == 1 {
            mediaHeaderRest = mediaHeaderPosition
        }
    }

    private func finishMediaHeaderDrag() {
        guard let drag = mediaHeaderDrag else { return }
        mediaHeaderDrag = nil
        snapMediaHeader(to: drag.destination(from: mediaHeaderPosition,
                                             minimumDistance: mediaHeaderMinimumDistance))
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

    private struct MediaHeaderDrag {
        let origin: CGFloat
        private var translation: CGFloat = 0
        private var target: CGFloat = 0

        init(origin: CGFloat) { self.origin = origin }

        mutating func move(to translation: CGFloat, from position: CGFloat, travel: CGFloat) -> CGFloat {
            let movement = self.translation - translation
            self.translation = translation
            if movement != 0 {
                target = movement > 0 ? 1 : 0
            }
            return min(1, max(0, position + movement / max(travel, 1)))
        }

        func destination(from position: CGFloat, minimumDistance: CGFloat) -> CGFloat {
            if position == 0 || position == 1 { return position }
            return abs(translation) < minimumDistance ? origin : target
        }
    }

    private struct MediaHeaderSnap: Equatable {
        let start: Date
        let initial: CGFloat
        let target: CGFloat
        private static let duration: TimeInterval = 0.22

        var end: Date { start.addingTimeInterval(Self.duration) }

        func position(at date: Date) -> CGFloat {
            let elapsed = CGFloat(date.timeIntervalSince(start) / Self.duration)
            if elapsed >= 1 { return target }
            let remaining = 1 - max(0, elapsed)
            return target + (initial - target) * remaining * remaining * remaining
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

private struct VesperWindowTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
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
