import AppKit
import OSLog
import UserNotifications

/// System notifications. Best effort throughout: without the notification
/// permission (see `PermissionManager`) nothing is shown and the app carries on.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let clipCategory = "clipSaved"
    private static let revealAction = "reveal"
    private static let pathKey = "path"

    private let logger = Logger(subsystem: "com.mertozturk.ClipApp", category: "notifications")
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        registerActions()
    }

    /// The action's title is fixed when the category is registered, so this
    /// runs again before each notification that carries it.
    private func registerActions() {
        let reveal = UNNotificationAction(identifier: Self.revealAction, title: AppLanguage.string("Show in Finder"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.clipCategory, actions: [reveal], intentIdentifiers: []),
        ])
    }

    /// A saved clip or recording; the notification reveals the file.
    func saved(_ url: URL, title: String) {
        registerActions()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = url.lastPathComponent
        content.categoryIdentifier = Self.clipCategory
        content.userInfo = [Self.pathKey: url.path]
        post(content, identifier: UUID().uuidString)
    }

    /// A later message with the same `identifier` replaces the earlier one.
    func show(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        post(content, identifier: identifier)
    }

    private func post(_ content: UNNotificationContent, identifier: String) {
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { [logger] error in
            if let error {
                logger.info("Notification not shown: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // A menu bar app counts as frontmost while its menu or a window is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Both the action button and a click on the notification reveal the clip.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier != UNNotificationDismissActionIdentifier,
           let path = response.notification.request.content.userInfo[Self.pathKey] as? String {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        completionHandler()
    }
}
