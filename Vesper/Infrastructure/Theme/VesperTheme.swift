import SwiftUI

enum VesperTheme {
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
