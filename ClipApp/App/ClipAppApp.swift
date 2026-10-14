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
            MenuBarLabel(controller: appDelegate.controller)
        }
    }
}

/// The menu bar icon; red with a running time while a recording is going.
private struct MenuBarLabel: View {
    @ObservedObject var controller: ClipController

    private static let recordingIcon: NSImage = {
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) ?? NSImage()
        // A template image would be drawn in the menu bar's own color.
        image.isTemplate = false
        return image
    }()

    var body: some View {
        if let seconds = controller.recordingSeconds {
            Image(nsImage: Self.recordingIcon)
            Text(verbatim: ClipFormat.duration(TimeInterval(seconds)))
        } else {
            Image(systemName: "record.circle")
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
        controller.onOpenSettings = { [windows] in windows.showMain(.settings) }
        if !permissions.screenRecordingGranted {
            // Nothing works without it, so the window opens where it is granted,
            // whatever the launch was.
            windows.showMain(.settings)
        } else if settings.openWindowAtLaunch, !Self.launchedAsLoginItem {
            // Started by the system at login, the app stays in the menu bar.
            windows.showMain(.allClips)
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
