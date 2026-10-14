import AppKit

/// The app a clip is filed under.
struct GameContext {
    /// Used when nothing that could be a game was in front.
    static let desktop = "Desktop"

    let name: String
    let bundleID: String?

    /// A name that is safe as a folder: no separators, control characters or
    /// leading dots. Falls back to `desktop` when nothing is left.
    static func folderName(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines))
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? desktop : cleaned
    }
}

/// Follows which app is in front, so a clip saved from ClipApp's own window
/// is still filed under the game that was just being played.
@MainActor
final class GameTracker {
    /// ClipApp itself and the pieces of macOS that own the desktop; none of
    /// them is ever what a clip shows.
    private static let ignored: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.loginwindow", "com.apple.Spotlight",
        "com.apple.WindowManager", "com.apple.screencaptureui", "com.apple.ScreenSaver.Engine",
    ]

    /// The last app in front that could be a game.
    private var remembered: GameContext?
    /// When that app stopped being in front; `nil` while it still is.
    private var leftFrontAt: Date?
    private var observer: NSObjectProtocol?

    init() {
        activated(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.activated(app) }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// What a clip reaching `window` seconds back from now belongs to: the app
    /// in front, or, when that is ClipApp or part of the system, the last
    /// other app, provided it was still in front within the window.
    func current(within window: TimeInterval) -> GameContext {
        if let front = Self.context(for: NSWorkspace.shared.frontmostApplication) { return front }
        guard let remembered else { return GameContext(name: GameContext.desktop, bundleID: nil) }
        if let leftFrontAt, Date().timeIntervalSince(leftFrontAt) > window {
            return GameContext(name: GameContext.desktop, bundleID: nil)
        }
        return remembered
    }

    private func activated(_ app: NSRunningApplication?) {
        if let context = Self.context(for: app) {
            remembered = context
            leftFrontAt = nil
        } else if remembered != nil, leftFrontAt == nil {
            // Later ignored apps (ClipApp, then Finder, …) do not move this.
            leftFrontAt = Date()
        }
    }

    /// `nil` for ClipApp, the ignored system apps and anything without a name.
    private static func context(for app: NSRunningApplication?) -> GameContext? {
        guard let app, let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier, !ignored.contains(bundleID),
              let name = app.localizedName else { return nil }
        return GameContext(name: GameContext.folderName(name), bundleID: bundleID)
    }
}
