import SwiftUI
import UIKit

/// Attach directly to the root ScrollView/List inside its existing NavigationStack.
private struct VesperImmersiveTitle: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state = ImmersiveTitleState()
    @State private var isTitleCollapsed = false
    @State private var isScrolling = false

    func body(content: Content) -> some View {
        content
            .environment(\.vesperTitleCollapsed, isTitleCollapsed)
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
            .onDisappear {
                isScrolling = false
                state.settle()
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { isTitleCollapsed = state.isCollapsed }
            }
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
    func vesperImmersiveTitle() -> some View {
        modifier(VesperImmersiveTitle())
    }
}

private struct VesperTitleCollapsedKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var vesperTitleCollapsed: Bool {
        get { self[VesperTitleCollapsedKey.self] }
        set { self[VesperTitleCollapsedKey.self] = newValue }
    }
}

/// A real scroll-content item, never a fixed overlay. Its layout height stays
/// stable while its contents animate, so scroll geometry cannot feed back.
struct VesperLargeTitle: View {
    let title: LocalizedStringKey
    @Environment(\.vesperTitleCollapsed) private var isCollapsed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var height: CGFloat = 80

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.largeTitle.bold())
            .foregroundStyle(Color("VesperPrimaryText"))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .background(.regularMaterial)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .offset(y: isCollapsed && !reduceMotion ? -height : 0)
            .opacity(isCollapsed ? 0 : 1)
            .clipped()
            .accessibilityAddTraits(.isHeader)
            .accessibilityHidden(isCollapsed)
            .allowsHitTesting(false)
    }
}

/// Draw only in the window's top system safe area from the shared root layer. No SwiftUI state updates or per-page fixed heights.
struct VesperStatusBarMaterial: UIViewRepresentable {
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
