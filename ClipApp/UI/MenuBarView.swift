import SwiftUI

struct MenuBarView: View {
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: ClipController
    @ObservedObject var capture: CaptureManager
    let windows: WindowManager

    var body: some View {
        Text(statusText)
        if case .running = capture.state {
            Text("Frames in the last second: \(capture.framesLastSecond)")
        }
        if let seconds = controller.byteLimitedSeconds {
            Text("Memory cap active: content exceeds the target bitrate, keeping the last ~\(seconds) s")
        }
        if settings.microphoneEnabled, permissions.microphoneStatus != .granted {
            Text("No microphone permission, clips have no microphone")
        }
        Divider()
        Button(controller.isSaving
               ? String(localized: "Saving Clip…")
               : String(localized: "Save Last \(settings.bufferSeconds) Seconds")) {
            controller.saveClip()
        }
        .disabled(controller.isSaving)
        switch controller.lastResult {
        case .saved(let url): Text("Last clip: \(url.lastPathComponent)")
        case .failed(let message): Text("Couldn't save clip: \(message)")
        case nil: EmptyView()
        }
        Button("Open Clips Folder") {
            controller.openClipDirectory()
        }
        Divider()
        Button("Open ClipApp") {
            windows.showMain(.clips)
        }
        Button("Settings…") {
            windows.showMain(.settings)
        }
        .keyboardShortcut(",")
        Button("Permissions…") {
            windows.showPermissions()
        }
        Divider()
        Button("Quit ClipApp") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        guard permissions.screenRecordingGranted else { return String(localized: "Screen Recording permission required") }
        switch capture.state {
        case .idle: return String(localized: "Capture off")
        case .starting: return String(localized: "Starting capture…")
        case .running(let source, let width, let height, let usingFallback):
            return usingFallback
                ? String(localized: "Capturing: \(source) · \(width)×\(height) (selected source unavailable)")
                : String(localized: "Capturing: \(source) · \(width)×\(height)")
        case .failed(let message): return String(localized: "Capture error, retrying: \(message)")
        case .permissionDenied: return String(localized: "No Screen Recording permission, capture stopped")
        }
    }
}
