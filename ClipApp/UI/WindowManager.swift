import AppKit
import Combine
import SwiftUI

/// Hosts SwiftUI views in plain AppKit windows. An LSUIElement app has no
/// reliable way to open a SwiftUI scene conditionally at launch.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private static let mainID = "main"
    private static let permissionsID = "permissions"
    static let mainFrameName = "MainWindow"

    let navigation = MainNavigation()

    private let settings: SettingsStore
    private let permissions: PermissionManager
    private let controller: ClipController
    private var windows: [String: NSWindow] = [:]
    /// Starts watching the save folder the first time the window is shown.
    private lazy var library = ClipLibrary(settings: settings, controller: controller)
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore, permissions: PermissionManager, controller: ClipController) {
        self.settings = settings
        self.permissions = permissions
        self.controller = controller
        super.init()
        // A window title is set once, so it has to follow the language by hand.
        settings.$language
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.windows[Self.permissionsID]?.title = AppLanguage.string("ClipApp Permissions")
            }
            .store(in: &cancellables)
    }

    func showPermissions() {
        show(id: Self.permissionsID, title: AppLanguage.string("ClipApp Permissions")) {
            LanguageRoot(settings: settings) { [permissions] in
                PermissionView(permissions: permissions)
            }
        }
    }

    /// Brings the main window forward; `tab` nil keeps the one it was on.
    /// While it is open the app has a Dock icon, see `windowWillClose`.
    func showMain(_ tab: MainTab? = nil) {
        if let tab { navigation.tab = tab }
        if windows[Self.mainID] == nil { windows[Self.mainID] = makeMainWindow() }
        NSApp.setActivationPolicy(.regular)
        show(windows[Self.mainID]!)
    }

    private func makeMainWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: LanguageRoot(settings: settings) { [self] in
            MainWindowView(
                navigation: navigation,
                settings: settings,
                permissions: permissions,
                controller: controller,
                capture: controller.capture,
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

    private func show<Content: View>(id: String, title: String, @ViewBuilder content: () -> Content) {
        if windows[id] == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            windows[id] = window
        }
        show(windows[id]!)
    }

    private func show(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate (main window only)

    /// Closing the window only hides the interface: the app goes back to the
    /// menu bar and capture keeps running.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
