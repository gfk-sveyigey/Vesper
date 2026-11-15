import SwiftUI
import UIKit

/// Root headers live in scroll content; system navigation remains available.
private struct VesperRootNavigationTitle: ViewModifier {
    let title: LocalizedStringKey
    @Environment(\.vesperWindowTopInset) private var windowTopInset

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, windowTopInset, for: .scrollContent)
            .ignoresSafeArea(.container, edges: .top)
            .background(RootNavigationTouchPassthrough().allowsHitTesting(false))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(false, for: .top)
    }
}

/// A normal scroll-content row, including any page-specific trailing actions.
struct VesperLargeTitle<Actions: View>: View {
    let title: LocalizedStringKey
    private let actions: Actions
    @ScaledMetric(relativeTo: .largeTitle) private var minimumRowHeight = 52

    init(title: LocalizedStringKey, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        Text(title)
            .font(.largeTitle.bold())
            .foregroundStyle(Color("VesperPrimaryText"))
            .padding(.trailing, 60)
            .frame(maxWidth: .infinity, minHeight: minimumRowHeight, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            // Actions do not participate in sizing or reposition the title text.
            .overlay(alignment: .trailing) { actions }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)
    }
}

extension VesperLargeTitle where Actions == EmptyView {
    init(title: LocalizedStringKey) {
        self.init(title: title) { EmptyView() }
    }
}

/// All root pages, including empty states, use the same viewport and header.
struct VesperRootScrollView<Actions: View, Content: View>: View {
    let title: LocalizedStringKey
    private let actions: Actions
    private let content: (CGFloat) -> Content
    @Environment(\.vesperWindowTopInset) private var windowTopInset
    @State private var headerHeight: CGFloat = 72

    init(title: LocalizedStringKey, @ViewBuilder content: @escaping (CGFloat) -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.content = content
        self.actions = actions()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VesperLargeTitle(title: title) { actions }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                    content(max(0, geometry.size.height - windowTopInset - headerHeight - 40))
                }
                .padding(.bottom, 20)
            }
        }
        .vesperRootNavigationTitle(title)
    }
}

extension VesperRootScrollView where Actions == EmptyView {
    init(title: LocalizedStringKey, @ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.init(title: title, content: content) { EmptyView() }
    }
}

extension View {
    func vesperRootNavigationTitle(_ title: LocalizedStringKey) -> some View {
        modifier(VesperRootNavigationTitle(title: title))
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

/// Scoped to a root page with no navigation-bar controls. The bar stays visible,
/// but cannot intercept the scroll-content header underneath it.
private struct RootNavigationTouchPassthrough: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.updateInteraction()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restoreInteraction()
    }

    final class Controller: UIViewController {
        private var isPageVisible = false
        private weak var managedBar: UINavigationBar?
        private var previousInteraction: Bool?

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            isPageVisible = true
            updateInteraction()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isPageVisible = true
            updateInteraction()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            updateInteraction()
        }

        override func viewWillDisappear(_ animated: Bool) {
            isPageVisible = false
            restoreInteraction()
            super.viewWillDisappear(animated)
        }

        func updateInteraction() {
            guard isPageVisible else { return }
            guard let navigation = navigationController, navigation.viewControllers.count == 1 else {
                restoreInteraction()
                return
            }
            let bar = navigation.navigationBar
            if managedBar !== bar {
                restoreInteraction()
                managedBar = bar
                previousInteraction = bar.isUserInteractionEnabled
            }
            bar.isUserInteractionEnabled = false
        }

        func restoreInteraction() {
            if let bar = managedBar, let previousInteraction {
                bar.isUserInteractionEnabled = previousInteraction
            }
            managedBar = nil
            previousInteraction = nil
        }
    }
}
