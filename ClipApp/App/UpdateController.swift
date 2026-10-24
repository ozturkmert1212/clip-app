import Combine
import Sparkle

/// Sparkle's updater, started once at launch and shared by the menu bar menu
/// and Settings. The feed, the key and the daily check are in Info.plist; an
/// update that is found is offered, never installed without asking.
@MainActor
final class UpdateController: ObservableObject {
    /// False while a check or an update is already under way.
    @Published private(set) var canCheckForUpdates = false

    #if DEBUG
    private let delegate: SPUUpdaterDelegate? = DebugFeedOverride()
    #else
    private let delegate: SPUUpdaterDelegate? = nil
    #endif
    private let controller: SPUStandardUpdaterController

    init() {
        // Sparkle keeps only a weak reference to its delegate.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Stored by Sparkle in the app's user defaults.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

#if DEBUG
/// Debug builds only: `-ClipAppFeedURLOverride <url>` on the command line, or
/// the same key in the app's defaults, points the updater at a test feed.
private final class DebugFeedOverride: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "ClipAppFeedURLOverride")
    }
}
#endif
