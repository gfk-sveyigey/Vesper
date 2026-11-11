import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case media, sources, history, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .media: "媒体"
        case .sources: "来源"
        case .history: "记录"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .media: "film"
        case .sources: "externaldrive"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}
