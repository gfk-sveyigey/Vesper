import SwiftUI
import Foundation
import UIKit

enum VesperTheme {
    static let background = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark { return .systemBackground }
        return UIColor(named: "VesperBackground", in: .main, compatibleWith: traits) ?? .systemBackground
    })

    static func accent(_ identifier: String) -> Color {
        if identifier.hasPrefix("#"), identifier.count == 7,
           let rgb = UInt32(identifier.dropFirst(), radix: 16) {
            return Color(.sRGB, red: Double((rgb >> 16) & 0xff) / 255,
                         green: Double((rgb >> 8) & 0xff) / 255,
                         blue: Double(rgb & 0xff) / 255, opacity: 1)
        }
        // Existing saved presets remain readable; new choices use ColorPicker.
        switch identifier {
        case "ocean": return Color(red: 0.20, green: 0.42, blue: 0.78)
        case "emerald": return Color(red: 0.13, green: 0.52, blue: 0.38)
        case "rose": return Color(red: 0.76, green: 0.27, blue: 0.43)
        default: return Color("VesperAccent")
        }
    }

    static func accentIdentifier(for color: Color) -> String? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        func byte(_ component: CGFloat) -> Int {
            Int((min(1, max(0, component)) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    static func colorScheme(_ appearance: String) -> ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

enum VesperLocalization {
    static func locale(for language: String) -> Locale {
        language == "system" ? .autoupdatingCurrent : Locale(identifier: language)
    }

    static func string(_ key: String, language: String? = nil) -> String {
        let code = language ?? UserDefaults.standard.string(forKey: "language.code") ?? "system"
        guard code != "system",
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return NSLocalizedString(key, comment: "")
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// Shared system navigation layout; each NavigationStack still owns its history.
struct VesperNavigationStyle: ViewModifier {
    var titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(titleDisplayMode)
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationBarBackButtonHidden(false)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.automatic, for: .navigationBar)
            .toolbarColorScheme(nil, for: .navigationBar)
            .toolbarRole(.editor)
    }
}

extension View {
    /// Keep the localized navigation title for native back history, while the
    /// principal item suppresses only its visible presentation in the bar.
    func vesperNavigationTitle(_ title: LocalizedStringKey) -> some View {
        navigationTitle(title)
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

    func vesperNavigationStyle(
        _ titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline
    ) -> some View {
        modifier(VesperNavigationStyle(titleDisplayMode: titleDisplayMode))
    }

    func vesperSystemNavigationBar() -> some View {
        toolbarBackground(.automatic, for: .navigationBar)
    }
}
