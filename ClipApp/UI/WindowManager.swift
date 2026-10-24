import AppKit
import SwiftUI

/// Hosts the main window's SwiftUI view in a plain AppKit window. With
/// `LSUIElement` there is no reliable way to open a SwiftUI scene
/// conditionally at launch.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let mainFrameName = "MainWindow"

    let navigation = MainNavigation()

    private let settings: SettingsStore
    private let permissions: PermissionManager
    private let controller: ClipController
    private let updates: UpdateController
    private var mainWindow: NSWindow?
    /// Starts watching the save folder the first time the window is shown.
    private lazy var library = ClipLibrary(settings: settings)

    init(settings: SettingsStore, permissions: PermissionManager, controller: ClipController, updates: UpdateController) {
        self.settings = settings
        self.permissions = permissions
        self.controller = controller
        self.updates = updates
    }

    /// Brings the main window forward; `item` nil keeps what it was showing.
    /// Asking for Settings always lands at its top, where the permissions
    /// are. While the window is open the app has a Dock icon, see
    /// `windowWillClose`.
    func showMain(_ item: SidebarItem? = nil) {
        if let item { navigation.selection = item }
        if item == .settings { navigation.settingsVisit += 1 }
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeMainWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: LanguageRoot(settings: settings) { [self] in
            MainWindowView(
                navigation: navigation,
                settings: settings,
                permissions: permissions,
                controller: controller,
                capture: controller.capture,
                updates: updates,
                library: library
            )
        })
        // The window, not the content, decides the size.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "ClipApp"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 480)
        window.setContentSize(NSSize(width: 960, height: 640))
        window.center()
        // Restores the last frame if there is one, and saves it from here on.
        window.setFrameAutosaveName(Self.mainFrameName)
        window.delegate = self
        return window
    }

    // MARK: - NSWindowDelegate

    /// Closing the window only hides the interface: the app goes back to the
    /// menu bar and capture keeps running.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
