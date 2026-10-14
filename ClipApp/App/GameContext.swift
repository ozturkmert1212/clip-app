import AppKit

/// The app a clip is filed under: whatever is in front when it is saved.
struct GameContext {
    /// Used when nothing that could be a game is in front.
    static let desktop = "Desktop"

    let name: String
    let bundleID: String?

    /// ClipApp itself and the pieces of macOS that own the desktop.
    private static let ignored: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.loginwindow", "com.apple.Spotlight",
        "com.apple.WindowManager", "com.apple.screencaptureui", "com.apple.ScreenSaver.Engine",
    ]

    @MainActor
    static func current() -> GameContext {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier, !ignored.contains(bundleID),
              let name = app.localizedName else {
            return GameContext(name: desktop, bundleID: nil)
        }
        return GameContext(name: folderName(name), bundleID: bundleID)
    }

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
