import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case media, sources, history, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .media: VesperLocalization.string("媒体")
        case .sources: VesperLocalization.string("来源")
        case .history: VesperLocalization.string("记录")
        case .settings: VesperLocalization.string("设置")
        }
    }

    var symbol: String {
        let data = (UserDefaults.standard.string(forKey: "navigation.icons") ?? "{}").data(using: .utf8) ?? Data()
        let saved = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        if let symbol = saved[rawValue], iconChoices.contains(symbol) { return symbol }
        return defaultSymbol
    }

    var iconChoices: [String] {
        switch self {
        case .media: ["film", "play.rectangle", "tv", "photo.on.rectangle"]
        case .sources: ["externaldrive", "folder", "server.rack", "network"]
        case .history: ["clock.arrow.circlepath", "clock", "list.bullet", "calendar"]
        case .settings: ["gearshape", "gear", "slider.horizontal.3", "switch.2"]
        }
    }

    var defaultSymbol: String {
        switch self {
        case .media: "film"
        case .sources: "externaldrive"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    /// The tab group always uses the filled visual variant.
    var filledSymbol: String {
        switch symbol {
        case "film": "film.fill"
        case "play.rectangle": "play.rectangle.fill"
        case "tv": "tv.fill"
        case "photo.on.rectangle": "photo.on.rectangle.fill"
        case "externaldrive": "externaldrive.fill"
        case "folder": "folder.fill"
        case "server.rack": "server.rack"
        case "network": "network"
        case "clock.arrow.circlepath": "clock.fill"
        case "clock": "clock.fill"
        case "list.bullet": "list.bullet"
        case "calendar": "calendar"
        case "gearshape": "gearshape.fill"
        case "gear": "gear"
        case "slider.horizontal.3": "slider.horizontal.3"
        case "switch.2": "switch.2"
        default: symbol + ".fill"
        }
    }
}
