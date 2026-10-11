import KeyboardShortcuts
import OSLog

extension KeyboardShortcuts.Name {
    static let saveClip = Self("saveClip", default: .init(.r, modifiers: [.control, .option, .command]))
}

@MainActor
final class HotkeyManager {
    private let logger = Logger(subsystem: "com.mertozturk.ClipApp", category: "hotkey")

    init(onSaveClip: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .saveClip) { [logger] in
            logger.notice("Hotkey triggered: saveClip")
            onSaveClip()
        }
    }
}
