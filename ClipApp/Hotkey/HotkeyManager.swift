import KeyboardShortcuts
import OSLog

extension KeyboardShortcuts.Name {
    static let saveClip = Self("saveClip", default: .init(.r, modifiers: [.control, .option, .command]))
    /// Unassigned until the user picks one in Settings.
    static let toggleRecording = Self("toggleRecording")
}

@MainActor
final class HotkeyManager {
    private let logger = Logger(subsystem: "com.mertozturk.ClipApp", category: "hotkey")

    init(onSaveClip: @escaping () -> Void, onToggleRecording: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .saveClip) { [logger] in
            logger.notice("Hotkey triggered: saveClip")
            onSaveClip()
        }
        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [logger] in
            logger.notice("Hotkey triggered: toggleRecording")
            onToggleRecording()
        }
    }
}
