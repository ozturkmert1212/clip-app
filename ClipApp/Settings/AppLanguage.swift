import Foundation

/// The interface language, chosen in the app instead of following the system.
/// It is applied through the app's own `AppleLanguages`, which the system
/// reads once per process, so a change needs a relaunch.
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

    private static let key = "language"

    /// The language this process started with, and so the one on screen.
    private(set) static var launched = AppLanguage.english

    static var selected: AppLanguage {
        get { UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init) ?? .english }
        set {
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
}
