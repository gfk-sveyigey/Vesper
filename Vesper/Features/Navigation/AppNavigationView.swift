import SwiftUI

struct AppNavigationView: View {
    @State private var selection: AppSection = .media
    @State private var isExpanded = false
    @State private var mediaPath = NavigationPath()
    @State private var sourcesPath = NavigationPath()
    @State private var historyPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focusedSection: AppSection?

    var body: some View {
        ZStack {
            Color("VesperBackground").ignoresSafeArea()
            selectedContent
        }
        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            navigationControls
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .accessibilityAction(.escape) { closeSelector() }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: isExpanded)
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selection {
        case .media:
            NavigationStack(path: $mediaPath) {
                MediaView(openSources: { select(.sources) })
            }
        case .sources:
            NavigationStack(path: $sourcesPath) { SourcesView() }
        case .history:
            NavigationStack(path: $historyPath) { HistoryView() }
        case .settings:
            NavigationStack(path: $settingsPath) { SettingsView() }
        }
    }

    private var navigationControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                if isExpanded { sectionButtons(compact: false) }
                toggleButton
            }
            HStack(spacing: 0) {
                if isExpanded { sectionButtons(compact: true) }
                toggleButton
            }
        }
        .foregroundStyle(Color("VesperPrimaryText"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("主区域导航")
    }

    private func sectionButtons(compact: Bool) -> some View {
        ForEach(AppSection.allCases) { section in
            Button { select(section) } label: {
                if compact {
                    Image(systemName: section.symbol)
                        .frame(minWidth: 44, minHeight: 44)
                } else {
                    Label(section.title, systemImage: section.symbol)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                }
            }
            .buttonStyle(.glass)
            .tint(selection == section ? Color("VesperAccent") : nil)
            .accessibilityLabel(section.title)
            .accessibilityAddTraits(selection == section ? [.isSelected] : [])
            .accessibilityFocused($focusedSection, equals: section)
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private var toggleButton: some View {
        Button {
            isExpanded.toggle()
            AppLog.debug("navigation.selector_toggled", category: .navigation)
            if isExpanded { focusedSection = selection }
        } label: {
            Image(systemName: isExpanded ? "xmark" : "square.grid.2x2")
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(isExpanded ? "收起区域选择" : "切换区域")
        .accessibilityValue("当前：\(selection.title)，\(isExpanded ? "已展开" : "已收起")")
        .accessibilityHint("展开后可选择媒体、来源、记录或设置")
        .keyboardShortcut("m", modifiers: [.command, .shift])
    }

    private func select(_ section: AppSection) {
        AppLog.info("navigation.selected.\(section.rawValue)", category: .navigation)
        selection = section
        closeSelector()
    }

    private func closeSelector() {
        isExpanded = false
        focusedSection = nil
    }
}
