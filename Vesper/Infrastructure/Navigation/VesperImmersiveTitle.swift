import SwiftUI
import UIKit
import ObjectiveC.runtime

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

/// Installs a root-only hit-test policy on the existing navigation bar.
/// This leaves the bar's interaction state untouched and never participates
/// in TabView or tab-bar event handling.
private struct RootNavigationTouchPassthrough: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.updateNavigationBarPolicy()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restoreNavigationBar()
    }

    final class Controller: UIViewController {
        private weak var managedBar: UINavigationBar?
        private var originalClass: AnyClass?

        override func loadView() {
            view = PassthroughView()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updateNavigationBarPolicy()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            updateNavigationBarPolicy()
        }

        override func viewWillDisappear(_ animated: Bool) {
            restoreNavigationBar()
            super.viewWillDisappear(animated)
        }

        func updateNavigationBarPolicy() {
            guard let navigation = navigationController,
                  navigation.viewControllers.count == 1 else {
                restoreNavigationBar()
                return
            }

            let bar = navigation.navigationBar
            if managedBar !== bar {
                restoreNavigationBar()
                managedBar = bar
                originalClass = object_getClass(bar)
            }

            guard object_getClass(bar) !== VesperPassthroughNavigationBar.self else { return }
            object_setClass(bar, VesperPassthroughNavigationBar.self)
        }

        func restoreNavigationBar() {
            guard let bar = managedBar, let originalClass else {
                managedBar = nil
                self.originalClass = nil
                return
            }
            if object_getClass(bar) === VesperPassthroughNavigationBar.self {
                object_setClass(bar, originalClass)
            }
            managedBar = nil
            self.originalClass = nil
        }
    }

    private final class PassthroughView: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}

private final class VesperPassthroughNavigationBar: UINavigationBar {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let titleRegionHeight = min(bounds.height, 56)
        let titleRegion = CGRect(
            x: 0,
            y: bounds.maxY - titleRegionHeight,
            width: bounds.width,
            height: titleRegionHeight
        )
        if titleRegion.contains(point), owningNavigationController?.viewControllers.count == 1 {
            return false
        }
        return super.point(inside: point, with: event)
    }

    private var owningNavigationController: UINavigationController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let navigation = next as? UINavigationController { return navigation }
            responder = next
        }
        return nil
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
    private let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VesperLargeTitle(title: title) { actions }
                content
            }
            .padding(.bottom, 20)
        }
        .vesperRootNavigationTitle(title)
    }
}

extension VesperRootScrollView where Actions == EmptyView {
    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
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
