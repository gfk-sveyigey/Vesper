import SwiftUI
import UIKit

/// Attach directly to the root ScrollView/List inside its existing NavigationStack.
private struct VesperImmersiveTitle: ViewModifier {
    let title: LocalizedStringKey
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state = ImmersiveTitleState()
    @State private var isTitleCollapsed = false
    @State private var isScrolling = false
    @State private var titleHeight: CGFloat = 88

    func body(content: Content) -> some View {
        content
            // This scrollable leading space stays constant during title animations,
            // avoiding layout/scroll-offset feedback when the title disappears.
            .contentMargins(.top, titleHeight, for: .scrollContent)
            .onScrollGeometryChange(for: Double.self) { geometry in
                Double(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, offset in
                observe(offset: offset)
            }
            .onScrollPhaseChange { _, phase in
                isScrolling = phase.isScrolling
                observe(offset: state.offset)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                titleOverlay
            }
            // Independent of the title's visibility, position and animation.
            .overlay {
                VesperStatusBarMaterial()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onDisappear {
                isScrolling = false
                state.settle()
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { isTitleCollapsed = state.isCollapsed }
            }
    }

    private var titleOverlay: some View {
        Color.clear
            .frame(height: titleHeight)
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color("VesperPrimaryText"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .background(.regularMaterial)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        if titleHeight != height { titleHeight = height }
                    }
                    .offset(y: reduceMotion || !isTitleCollapsed ? 0 : -titleHeight)
                    .opacity(isTitleCollapsed ? 0 : 1)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityHidden(isTitleCollapsed)
            }
            // Clip only the animated header, never the page or its safe areas.
            .clipped()
            .allowsHitTesting(false)
    }

    private func observe(offset: Double) {
        guard let transition = state.observe(offset: offset, isScrolling: isScrolling) else { return }
        withAnimation(
            .easeInOut(duration: reduceMotion ? 0.18 : 0.30),
            completionCriteria: .logicallyComplete
        ) {
            isTitleCollapsed = transition.isCollapsed
        } completion: {
            state.complete(transition)
        }
    }
}

extension View {
    func vesperImmersiveTitle(_ title: LocalizedStringKey) -> some View {
        modifier(VesperImmersiveTitle(title: title))
    }
}

/// Draw only in the window's top system safe area, even when this root page's
/// content starts below it. No SwiftUI state updates or per-page fixed heights.
private struct VesperStatusBarMaterial: UIViewRepresentable {
    func makeUIView(context: Context) -> StatusBarMaterialView { StatusBarMaterialView() }
    func updateUIView(_ view: StatusBarMaterialView, context: Context) { view.setNeedsLayout() }

    final class StatusBarMaterialView: UIView {
        private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            material.isUserInteractionEnabled = false
            addSubview(material)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            setNeedsLayout()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window else { material.frame = .zero; return }
            let statusArea = CGRect(
                x: window.bounds.minX, y: window.bounds.minY,
                width: window.bounds.width, height: window.safeAreaInsets.top
            )
            material.frame = convert(statusArea, from: window)
        }
    }
}
