import SwiftUI

struct MenuBarView: View {
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: ClipController
    @ObservedObject var capture: CaptureManager
    let windows: WindowManager

    // Menu items are AppKit in the end, so every title is looked up in the
    // chosen language here instead of relying on the environment.
    var body: some View {
        Text(verbatim: statusText)
        if case .running = capture.state {
            Text(verbatim: AppLanguage.string("Frames in the last second: \(capture.framesLastSecond)"))
        }
        if let seconds = controller.byteLimitedSeconds {
            Text(verbatim: AppLanguage.string("Memory cap active: content exceeds the target bitrate, keeping the last ~\(seconds) s"))
        }
        if settings.microphoneEnabled, permissions.microphoneStatus != .granted {
            Text(verbatim: AppLanguage.string("No microphone permission, clips have no microphone"))
        }
        Divider()
        Button(controller.isSaving
               ? AppLanguage.string("Saving Clip…")
               : AppLanguage.string("Save Last \(settings.bufferSeconds) Seconds")) {
            controller.saveClip()
        }
        .disabled(controller.isSaving)
        Button(controller.recordingSeconds.map { AppLanguage.string("Stop Recording (\(ClipFormat.duration(TimeInterval($0))))") }
               ?? AppLanguage.string("Start Recording")) {
            controller.toggleRecording()
        }
        switch controller.lastResult {
        case .saved(let url): Text(verbatim: AppLanguage.string("Last clip: \(url.lastPathComponent)"))
        case .failed(let message): Text(verbatim: AppLanguage.string("Couldn't save clip: \(message)"))
        case nil: EmptyView()
        }
        Button(AppLanguage.string("Open Clips Folder")) {
            controller.openClipDirectory()
        }
        Divider()
        Button(AppLanguage.string("Open ClipApp")) {
            windows.showMain(.allClips)
        }
        Button(AppLanguage.string("Settings…")) {
            windows.showMain(.settings)
        }
        .keyboardShortcut(",")
        Button(AppLanguage.string("Permissions…")) {
            windows.showPermissions()
        }
        Divider()
        Button(AppLanguage.string("Quit ClipApp")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        guard permissions.screenRecordingGranted else { return AppLanguage.string("Screen Recording permission required") }
        switch capture.state {
        case .idle: return AppLanguage.string("Capture off")
        case .starting: return AppLanguage.string("Starting capture…")
        case .running(let source, let width, let height, let usingFallback):
            return usingFallback
                ? AppLanguage.string("Capturing: \(source) · \(width)×\(height) (selected source unavailable)")
                : AppLanguage.string("Capturing: \(source) · \(width)×\(height)")
        case .failed(let message): return AppLanguage.string("Capture error, retrying: \(message)")
        case .permissionDenied: return AppLanguage.string("No Screen Recording permission, capture stopped")
        }
    }
}
