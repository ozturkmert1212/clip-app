import Foundation

/// How an update found by a scheduled check (or the check at launch) reaches
/// the user, as plain values; `UpdateController` feeds it what the app is
/// doing when Sparkle asks. Sparkle's own window only comes up when the user
/// is looking at ClipApp and not in the middle of clipping or a recording.
/// Otherwise the update waits as a reminder in the menu bar menu and the
/// sidebar, with one notification per version while the app is in the
/// background. A check the user started is always shown by Sparkle and
/// never comes through here.
enum UpdateReminder {
    /// What the app is doing when a scheduled check has found an update.
    struct Situation: Equatable {
        /// "Check for updates automatically"; off, nothing is shown at all.
        var checksAutomatically: Bool
        var appIsActive: Bool
        var mainWindowVisible: Bool
        /// Sparkle proposes to put the update in front right away: the app
        /// was launched recently or the system has been idle.
        var immediateFocus: Bool
        /// Clipping or a recording runs.
        var isCapturing: Bool
        /// The notification permission is granted; it is never asked for here.
        var notificationsAllowed: Bool
    }

    enum Presentation: Equatable {
        /// Sparkle shows its update window.
        case sparkleWindow
        /// Sparkle keeps the update in the background and the app reminds of it.
        case reminder
        /// Automatic checks are off.
        case nothing
    }

    struct Surfaces: OptionSet {
        let rawValue: Int
        /// "Update available: ClipApp X.Y.Z…" at the top of the menu bar menu.
        static let menu = Surfaces(rawValue: 1 << 0)
        /// The box above Settings in the main window's sidebar.
        static let sidebar = Surfaces(rawValue: 1 << 1)
        /// A system notification, once per version.
        static let notification = Surfaces(rawValue: 1 << 2)
    }

    /// The defaults key holding the last version a notification went out for.
    static let notifiedVersionKey = "notifiedUpdateVersion"

    static func presentation(in situation: Situation) -> Presentation {
        guard situation.checksAutomatically else { return .nothing }
        let userIsHere = situation.appIsActive && situation.mainWindowVisible && situation.immediateFocus
        return userIsHere && !situation.isCapturing ? .sparkleWindow : .reminder
    }

    /// Where `version` shows up. `notifiedVersion` is the version the last
    /// notification was about: the same version never gets a second one.
    static func surfaces(for version: String, in situation: Situation, notifiedVersion: String?) -> Surfaces {
        guard presentation(in: situation) == .reminder else { return [] }
        var surfaces: Surfaces = [.menu, .sidebar]
        if situation.notificationsAllowed, !situation.appIsActive, notifiedVersion != version {
            surfaces.insert(.notification)
        }
        return surfaces
    }
}
