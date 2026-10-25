import AppKit
import Combine
import OSLog
import Sparkle

/// Sparkle's updater, started once the app has finished launching and shared
/// by the menu bar menu, the main window and Settings. The feed, the key and
/// the check interval (6 hours) are in Info.plist; an update that is found is
/// offered, never installed without asking. Updates found by a scheduled
/// check use Sparkle's gentle reminders: see `UpdateReminder` for when
/// Sparkle's window comes up and when the app reminds of the update instead.
@MainActor
final class UpdateController: ObservableObject {
    /// False while a check or an update is already under way.
    @Published private(set) var canCheckForUpdates = false
    /// The version a scheduled check found while the user was elsewhere,
    /// waiting in the menu bar menu and the sidebar; nil once the user has
    /// turned to it or the update session is over.
    @Published private(set) var availableUpdate: String?

    /// Filled in by `AppDelegate`: what the app is doing when an update is found.
    var isMainWindowVisible: () -> Bool = { false }
    var isCapturing: () -> Bool = { false }
    var notificationsAllowed: () -> Bool = { false }
    /// Posts the "ClipApp X.Y.Z is available" notification.
    var notify: (String) -> Void = { _ in }

    #if DEBUG
    private let delegate: SPUUpdaterDelegate? = DebugFeedOverride()
    #else
    private let delegate: SPUUpdaterDelegate? = nil
    #endif
    private let reminders = GentleReminders()
    private let logger = Logger(subsystem: "com.mertozturk.ClipApp", category: "updates")
    private let controller: SPUStandardUpdaterController
    /// The situation Sparkle was answered with, for the call that follows it.
    private var pendingSituation: UpdateReminder.Situation?

    init() {
        // Sparkle keeps only weak references to its delegates.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: reminders)
        reminders.owner = self
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Starts the updater and, unless automatic checks are off, looks for an
    /// update right away; Sparkle's own schedule carries on from there.
    /// Sparkle wants that extra check made right after starting, and the
    /// rest of the app is in place by then to answer where to show it.
    func start() {
        controller.startUpdater()
        if controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    /// Stored by Sparkle in the app's user defaults.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
            if !newValue { availableUpdate = nil }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// The reminders lead here: the app comes forward and Sparkle shows the
    /// update it kept waiting in its window.
    func showUpdate() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: - Gentle reminders

    fileprivate func sparkleShowsScheduledUpdate(_ update: SUAppcastItem, immediateFocus: Bool) -> Bool {
        let situation = UpdateReminder.Situation(
            checksAutomatically: controller.updater.automaticallyChecksForUpdates,
            appIsActive: NSApp.isActive,
            mainWindowVisible: isMainWindowVisible(),
            immediateFocus: immediateFocus,
            isCapturing: isCapturing(),
            notificationsAllowed: notificationsAllowed()
        )
        pendingSituation = situation
        let presentation = UpdateReminder.presentation(in: situation)
        logger.notice("Update \(update.displayVersionString, privacy: .public) found: \(String(describing: presentation), privacy: .public) (\(String(describing: situation), privacy: .public))")
        return presentation == .sparkleWindow
    }

    fileprivate func willShow(_ update: SUAppcastItem, handledBySparkle: Bool) {
        defer { pendingSituation = nil }
        guard !handledBySparkle, let situation = pendingSituation else { return }
        let version = update.displayVersionString
        let defaults = UserDefaults.standard
        let surfaces = UpdateReminder.surfaces(
            for: version, in: situation,
            notifiedVersion: defaults.string(forKey: UpdateReminder.notifiedVersionKey)
        )
        if !surfaces.isDisjoint(with: [.menu, .sidebar]) { availableUpdate = version }
        if surfaces.contains(.notification) {
            defaults.set(version, forKey: UpdateReminder.notifiedVersionKey)
            notify(version)
        }
    }

    fileprivate func reminderDone() {
        availableUpdate = nil
    }
}

/// Sparkle's standard user driver calls its delegate on the main thread, but
/// unlike the updater's delegate the protocol is not marked for the main
/// actor, so the answers are handed over from here.
private final class GentleReminders: NSObject, SPUStandardUserDriverDelegate {
    weak var owner: UpdateController?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        MainActor.assumeIsolated { owner?.sparkleShowsScheduledUpdate(update, immediateFocus: immediateFocus) ?? true }
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated { owner?.willShow(update, handledBySparkle: handleShowingUpdate || state.userInitiated) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { owner?.reminderDone() }
    }

    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { owner?.reminderDone() }
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
