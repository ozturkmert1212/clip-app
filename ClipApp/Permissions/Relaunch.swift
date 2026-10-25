import Foundation

/// Starting ClipApp again (Restart ClipApp for Screen Recording, Restart for
/// the language): always the copy that is running, by its own path, whether
/// that is /Applications, a build folder or a dmg (the App Translocation path
/// included), never whichever copy the system finds for the bundle ID. A
/// second instance of the same copy is started first; this one only quits
/// once it is up, and stays if it could not be started.
///
/// System Settings' own "Quit & Reopen", offered after the Screen Recording
/// switch is flipped, does reopen by bundle ID: it brought up the copy in
/// /Applications while another copy had been running (seen in the system log).
/// That one is outside the app's hands.
enum Relaunch {
    static func target(for bundle: Bundle) -> URL {
        bundle.bundleURL
    }

    /// The running copy is still there when the new one starts.
    static let createsNewInstance = true

    /// Quitting without a new instance would leave nothing running, and the
    /// next ClipApp opened would likely be another copy.
    static func quitsAfterLaunch(error: Error?) -> Bool {
        error == nil
    }
}
