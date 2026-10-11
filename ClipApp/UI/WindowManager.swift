import AppKit
import SwiftUI

/// Hosts SwiftUI views in plain AppKit windows. An LSUIElement app has no
/// reliable way to open a SwiftUI scene conditionally at launch.
@MainActor
final class WindowManager {
    private var windows: [String: NSWindow] = [:]

    func showPermissions(_ permissions: PermissionManager) {
        show(id: "permissions", title: String(localized: "ClipApp Permissions")) {
            PermissionView(permissions: permissions)
        }
    }

    func showSettings(_ settings: SettingsStore, capture: CaptureManager, permissions: PermissionManager) {
        show(id: "settings", title: String(localized: "ClipApp Settings")) {
            SettingsView(settings: settings, permissions: permissions, capture: capture)
        }
    }

    private func show<Content: View>(id: String, title: String, @ViewBuilder content: () -> Content) {
        let window: NSWindow
        if let existing = windows[id] {
            window = existing
        } else {
            window = NSWindow(contentViewController: NSHostingController(rootView: content()))
            window.title = title
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            windows[id] = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
