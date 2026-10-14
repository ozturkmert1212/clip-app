import Foundation

/// What a display capture leaves out of ClipApp's own interface and of the
/// system's, as plain values so the rule can be tested without a stream.
///
/// With `showsClipApp` off (the default) ClipApp is excluded as an
/// application: the main window, its sheets, the menu bar menu and the HUD.
/// With it on only the HUD stays out, listed by window ID. Notification
/// Center is excluded either way.
struct CapturePrivacy: Equatable {
    static let notificationCenterBundleIdentifier = "com.apple.notificationcenterui"
    static let showsClipAppKey = "showClipAppInCaptures"
    static let showsClipAppDefault = false

    var showsClipApp: Bool
    let ownBundleIdentifier: String

    /// The stored setting, `showsClipAppDefault` when there is none (a first
    /// launch, or the first one after an update that added it).
    static func storedShowsClipApp(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: showsClipAppKey) as? Bool ?? showsClipAppDefault
    }

    /// Bundle identifiers whose every window a display capture leaves out.
    var excludedApplications: [String] {
        showsClipApp
            ? [Self.notificationCenterBundleIdentifier]
            : [ownBundleIdentifier, Self.notificationCenterBundleIdentifier]
    }

    /// Whether the windows that must never be captured (the HUD) have to be
    /// listed by ID: when ClipApp is shown, or could not be found to be
    /// excluded as a whole.
    func excludesHiddenWindowsByID(ownApplicationFound: Bool) -> Bool {
        showsClipApp || !ownApplicationFound
    }

    /// What ClipApp's ordinary windows tell the window server; the HUD is
    /// always `false`. Recent ScreenCaptureKit ignores this, the filter is
    /// what counts.
    var ordinaryWindowsShareable: Bool { showsClipApp }

    /// ClipApp is never offered as a window or application source, and one
    /// stored anyway falls back to the main display, so the setting stays the
    /// only way it ends up in a clip.
    func canBeSource(bundleIdentifier: String?) -> Bool {
        bundleIdentifier != ownBundleIdentifier
    }
}
