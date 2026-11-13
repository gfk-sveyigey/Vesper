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
        switch self {
        case .media: "film"
        case .sources: "externaldrive"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}
