import AppKit

/// The app a clip is filed under.
struct GameContext: Equatable {
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

/// An app as the game rules see it, so they can be used without AppKit.
struct FrontApp: Equatable {
    var name: String?
    var bundleID: String?
}

/// The rules behind `GameTracker`, as plain state: which app a clip belongs
/// to when the one in front is ClipApp itself or part of the system.
struct GameMemory {
    /// The pieces of macOS that own the desktop; like ClipApp itself, none of
    /// them is ever what a clip shows.
    static let ignored: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.loginwindow", "com.apple.Spotlight",
        "com.apple.WindowManager", "com.apple.screencaptureui", "com.apple.ScreenSaver.Engine",
    ]

    /// ClipApp's own bundle identifier.
    let ownBundleID: String?
    /// The last app in front that could be a game.
    private(set) var remembered: GameContext?
    /// When that app stopped being in front; `nil` while it still is.
    private(set) var leftFrontAt: Date?

    init(ownBundleID: String?) {
        self.ownBundleID = ownBundleID
    }

    /// `nil` for ClipApp, the ignored system apps and anything without a name.
    func context(for app: FrontApp?) -> GameContext? {
        guard let app, let bundleID = app.bundleID, bundleID != ownBundleID, !Self.ignored.contains(bundleID),
              let name = app.name else { return nil }
        return GameContext(name: GameContext.folderName(name), bundleID: bundleID)
    }

    /// To be called for every app that comes to the front.
    mutating func activated(_ app: FrontApp?, at time: Date) {
        if let context = context(for: app) {
            remembered = context
            leftFrontAt = nil
        } else if remembered != nil, leftFrontAt == nil {
            // Later ignored apps (ClipApp, then Finder, …) do not move this.
            leftFrontAt = time
        }
    }

    /// What a clip reaching `window` seconds back from `now` belongs to: the
    /// app in front, or, when that is ClipApp or part of the system, the last
    /// other app, provided it was still in front within the window.
    func current(front: FrontApp?, within window: TimeInterval, now: Date) -> GameContext {
        if let front = context(for: front) { return front }
        guard let remembered else { return GameContext(name: GameContext.desktop, bundleID: nil) }
        if let leftFrontAt, now.timeIntervalSince(leftFrontAt) > window {
            return GameContext(name: GameContext.desktop, bundleID: nil)
        }
        return remembered
    }
}

/// Follows which app is in front, so a clip saved from ClipApp's own window
/// is still filed under the game that was just being played.
@MainActor
final class GameTracker {
    private var memory = GameMemory(ownBundleID: Bundle.main.bundleIdentifier)
    private var observer: NSObjectProtocol?

    init() {
        memory.activated(Self.app(NSWorkspace.shared.frontmostApplication), at: Date())
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = Self.app(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            Task { @MainActor in self?.memory.activated(app, at: Date()) }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// See `GameMemory.current(front:within:now:)`.
    func current(within window: TimeInterval) -> GameContext {
        memory.current(front: Self.app(NSWorkspace.shared.frontmostApplication), within: window, now: Date())
    }

    nonisolated private static func app(_ app: NSRunningApplication?) -> FrontApp? {
        app.map { FrontApp(name: $0.localizedName, bundleID: $0.bundleIdentifier) }
    }
}
