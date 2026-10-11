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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissions: PermissionManager
    let settings: SettingsStore
    let controller: ClipController
    let windows = WindowManager()
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        permissions = PermissionManager()
        settings = SettingsStore()
        controller = ClipController(settings: settings, permissions: permissions)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Asked once at first launch; a refusal only costs the banners.
        permissions.requestNotificationsIfUndetermined()
        if !permissions.screenRecordingGranted {
            windows.showPermissions(permissions)
        }
        // Capture starts as soon as the permission is there, including at launch.
        permissions.$screenRecordingGranted
            .removeDuplicates()
            .sink { [controller] granted in
                if granted { controller.capture.start() }
            }
            .store(in: &cancellables)
    }
}
