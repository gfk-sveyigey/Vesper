import SwiftUI
import UIKit

// Navigation destinations can also inherit SwiftUI's isPresented = true.
// Mark actual sheet entry points explicitly instead of using it to infer a sheet.
private struct SettingsIntroCardsHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsIntroCardsHidden: Bool {
        get { self[SettingsIntroCardsHiddenKey.self] }
        set { self[SettingsIntroCardsHiddenKey.self] = newValue }
    }
}

/// Introductory card shared by secondary settings pages.
struct SettingsIntroCard: View {
    @Environment(\.settingsIntroCardsHidden) private var introCardsHidden
    let title: LocalizedStringKey
    let symbol: String
    let description: LocalizedStringKey
    @ScaledMetric(relativeTo: .largeTitle) private var iconSize = 28.0
    var body: some View {
        if !introCardsHidden {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: iconSize)).foregroundStyle(.white)
                    .frame(width: iconSize + 20, height: iconSize + 20)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(description).foregroundStyle(.secondary).font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }
}

/// Match the standard symbol-and-text labels used by tab settings.
struct SettingsLabel: View {
    let title: LocalizedStringKey
    let symbol: String

    init(_ title: LocalizedStringKey, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .font(.body)
                .foregroundStyle(Color(uiColor: .label))
        }
        .frame(minHeight: 28)
    }
}

/// Keep long setting titles readable without moving their controls below them.
private struct SettingsWrappingToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
        }
    }
}

private struct SettingsWrappingLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            configuration.content
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
    }
}

/// A single native grouped List owns every row and section on a settings page.
struct SettingsPage<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        List { content }
            .lineLimit(nil)
            .minimumScaleFactor(1)
            .toggleStyle(SettingsWrappingToggleStyle())
            .labeledContentStyle(SettingsWrappingLabeledContentStyle())
            .listStyle(.insetGrouped)
            .listSectionSpacing(20)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}

struct SettingsSection<Rows: View, Footer: View>: View {
    private let title: LocalizedStringKey?
    private let rows: Rows
    private let footer: Footer
    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Rows, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.rows = content()
        self.footer = footer()
    }
    var body: some View {
        Section {
            rows
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
        } header: {
            if let title { Text(title).textCase(nil) }
        } footer: { footer }
    }
}

extension SettingsSection where Footer == EmptyView {
    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Rows) {
        self.init(title, content: content, footer: { EmptyView() })
    }
}

/// Keep the selected value on one line and give it priority over the row label.
struct SettingsPicker<Selection: Hashable, Options: View, Label: View>: View {
    let selection: Binding<Selection>
    private let options: Options
    private let label: Label
    init(selection: Binding<Selection>, @ViewBuilder content: () -> Options, @ViewBuilder label: () -> Label) {
        self.selection = selection; self.options = content(); self.label = label()
    }
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            label.lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            Picker(selection: selection) { options } label: { label }
                .labelsHidden().pickerStyle(.menu)
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }
}

extension SettingsPicker where Label == Text {
    init(_ title: LocalizedStringKey, selection: Binding<Selection>, @ViewBuilder content: () -> Options) {
        self.init(selection: selection, content: content, label: { Text(title) })
    }
}
