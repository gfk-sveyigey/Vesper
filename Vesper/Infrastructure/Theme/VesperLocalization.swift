import Foundation

enum VesperLocalization {
    static func locale(for language: String) -> Locale {
        language == "system" ? .autoupdatingCurrent : Locale(identifier: language)
    }

    #if canImport(Darwin)
    /// Preserve interpolated localization keys while honoring the in-app language.
    static func localized(_ value: String.LocalizationValue) -> String {
        let code = UserDefaults.standard.string(forKey: "language.code") ?? "system"
        let bundle = code == "system" ? Bundle.main
            : Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return String(localized: value, bundle: bundle, locale: locale(for: code))
    }
    #endif

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
