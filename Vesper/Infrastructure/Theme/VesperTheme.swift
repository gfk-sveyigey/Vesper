import SwiftUI
import Foundation
import UIKit

enum VesperTheme {
    static let background = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark { return .systemBackground }
        return UIColor(named: "VesperBackground", in: .main, compatibleWith: traits) ?? .systemBackground
    })

    static func accent(_ identifier: String) -> Color {
        switch identifier {
        case "ocean": Color(red: 0.20, green: 0.42, blue: 0.78)
        case "emerald": Color(red: 0.13, green: 0.52, blue: 0.38)
        case "rose": Color(red: 0.76, green: 0.27, blue: 0.43)
        default: Color(red: 0.41, green: 0.35, blue: 0.78)
        }
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
            .navigationBarBackButtonHidden(false)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            .toolbarColorScheme(nil, for: .navigationBar)
            .toolbarRole(.editor)
    }
}

extension View {
    func vesperNavigationStyle(
        _ titleDisplayMode: NavigationBarItem.TitleDisplayMode = .inline
    ) -> some View {
        modifier(VesperNavigationStyle(titleDisplayMode: titleDisplayMode))
    }

    func vesperSystemNavigationBar() -> some View {
        toolbarBackground(.automatic, for: .navigationBar)
    }
}
