import SwiftUI

/// The language has to be pinned before SwiftUI or AppKit load any string.
@main
enum Main {
    static func main() {
        AppLanguage.applyAtLaunch()
        ClipAppApp.main()
    }
}

struct ClipAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            LanguageRoot(settings: appDelegate.settings) {
                MenuBarView(
                    permissions: appDelegate.permissions,
                    settings: appDelegate.settings,
                    controller: appDelegate.controller,
                    capture: appDelegate.controller.capture,
                    windows: appDelegate.windows
                )
            }
        } label: {
            MenuBarLabel(
                controller: appDelegate.controller,
                capture: appDelegate.controller.capture,
                permissions: appDelegate.permissions
            )
        }
    }
}

/// The menu bar icon, and nothing else: normal while clipping, with a red
/// dot while a recording runs, faded while clipping is off, failing or not
/// permitted (see `CaptureActivity.icon`).
private struct MenuBarLabel: View {
    @ObservedObject var controller: ClipController
    @ObservedObject var capture: CaptureManager
    @ObservedObject var permissions: PermissionManager

    var body: some View {
        Image(nsImage: icon)
            .accessibilityLabel(Text(verbatim: "ClipApp"))
    }

    private var icon: NSImage {
        // Recording only once the file is open, like the rest of the interface.
        var activity = controller.activity
        activity.isRecording = controller.isRecording
        switch activity.icon(captureWorks: captureWorks) {
        case .recording: return MenuBarIcon.shared.recording
        case .normal: return MenuBarIcon.shared.normal
        case .dimmed: return MenuBarIcon.shared.dimmed
        }
    }

    /// `.idle` only lasts until a stream that was just asked for begins starting.
    private var captureWorks: Bool {
        guard permissions.screenRecordingGranted else { return false }
        switch capture.state {
        case .idle, .starting, .running: return true
        case .failed, .permissionDenied: return false
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissions: PermissionManager
    let settings: SettingsStore
    let controller: ClipController
    let windows: WindowManager

    override init() {
        permissions = PermissionManager()
        settings = SettingsStore()
        controller = ClipController(settings: settings, permissions: permissions)
        windows = WindowManager(settings: settings, permissions: permissions, controller: controller)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Asked once at first launch; a refusal only costs the banners.
        permissions.requestNotificationsIfUndetermined()
        controller.onOpenSettings = { [windows] in windows.showMain(.settings) }
        if !permissions.screenRecordingGranted {
            // Nothing works without it, so the window opens where it is granted,
            // whatever the launch was.
            windows.showMain(.settings)
        } else if settings.openWindowAtLaunch, !Self.launchedAsLoginItem {
            // Started by the system at login, the app stays in the menu bar.
            windows.showMain(.allClips)
        }
        // Capture only starts when the user starts clipping or a recording.
    }

    /// A click on the Dock icon, or opening the app again while it runs.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.showMain()
        return false
    }

    /// Closing the window leaves capture running; only Quit ends the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A running recording is closed properly before the app goes away.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.isRecording else { return .terminateNow }
        Task {
            await controller.stopRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The launch Apple event says whether the system started the app as a
    /// login item. Only meaningful while the app is launching.
    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
