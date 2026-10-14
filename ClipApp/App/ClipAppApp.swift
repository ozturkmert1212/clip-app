import Combine
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
        MenuBarExtra("ClipApp", systemImage: "record.circle") {
            LanguageRoot(settings: appDelegate.settings) {
                MenuBarView(
                    permissions: appDelegate.permissions,
                    settings: appDelegate.settings,
                    controller: appDelegate.controller,
                    capture: appDelegate.controller.capture,
                    windows: appDelegate.windows
                )
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissions: PermissionManager
    let settings: SettingsStore
    let controller: ClipController
    let windows: WindowManager
    private var cancellables: Set<AnyCancellable> = []

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
        // Started by the system at login, the app stays in the menu bar.
        if settings.openWindowAtLaunch, !Self.launchedAsLoginItem {
            windows.showMain(.allClips)
        }
        if !permissions.screenRecordingGranted {
            windows.showPermissions()
        }
        // Capture starts as soon as the permission is there, including at launch.
        permissions.$screenRecordingGranted
            .removeDuplicates()
            .sink { [controller] granted in
                if granted { controller.capture.start() }
            }
            .store(in: &cancellables)
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

    /// The launch Apple event says whether the system started the app as a
    /// login item. Only meaningful while the app is launching.
    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
