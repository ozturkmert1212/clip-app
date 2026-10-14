import Foundation

/// The interface language, chosen in the app instead of following the system.
/// Our own strings are looked up in the chosen language on every use
/// (`string(_:)` outside views, `locale` in the SwiftUI environment inside
/// them), so a change shows at once. Text that macOS supplies follows the
/// app's `AppleLanguages`, which the system reads once per process: that part
/// only changes at the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case turkish = "tr"

    var id: String { rawValue }

    /// Each language is listed under its own name, whatever the interface language is.
    var title: String {
        switch self {
        case .english: return "English"
        case .turkish: return "Türkçe"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// The language's own `.lproj`, so a lookup cannot fall back to the
    /// language the process started with. English has no table there: its
    /// keys are the text.
    private var bundle: Bundle {
        Bundle.main.path(forResource: rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }

    private static let key = "language"

    /// The language this process started with; system-supplied text stays in it.
    private(set) static var launched = AppLanguage.english

    /// The language our own strings are shown in right now.
    private(set) static var current = AppLanguage.english

    static var selected: AppLanguage {
        get { UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init) ?? .english }
        set {
            current = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            UserDefaults.standard.set([newValue.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Has to run before anything looks up a localized string. Without a
    /// stored choice this pins English, even on a Turkish system.
    static func applyAtLaunch() {
        launched = selected
        selected = launched
    }

    /// For every string that is not a SwiftUI literal: notifications, the
    /// HUD, errors, window titles, menu items.
    static func string(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: current.bundle, locale: current.locale)
    }
}
