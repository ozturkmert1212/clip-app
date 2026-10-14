import SwiftUI

/// The menu bar menu: the controls that are wanted in the middle of a game.
/// Everything that is a preference lives in the Settings tab.
struct MenuBarView: View {
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: ClipController
    @ObservedObject var capture: CaptureManager
    let windows: WindowManager

    // Menu items are AppKit in the end, so every title is looked up in the
    // chosen language here instead of relying on the environment.
    var body: some View {
        // A missing permission takes the place of the status and leads to where it is fixed.
        if !permissions.screenRecordingGranted {
            Button(AppLanguage.string("Screen Recording permission needed")) { windows.showMain(.settings) }
        } else {
            Text(verbatim: statusText)
            if settings.microphoneEnabled, permissions.microphoneStatus != .granted {
                Button(AppLanguage.string("Microphone permission needed")) { windows.showMain(.settings) }
            }
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
        Divider()
        Menu(AppLanguage.string("Source")) {
            Text(verbatim: controller.isRecording
                 ? AppLanguage.string("The source can't be changed during a recording.")
                 : AppLanguage.string("Changing the source restarts capture and clears the replay buffer."))
            // A saved window or app that is gone still shows as the selection.
            if !capture.sources.contains(settings.source) {
                Toggle(AppLanguage.string("Unavailable (capturing the main display)"), isOn: .constant(true))
                    .disabled(true)
            }
            sourceSection(AppLanguage.string("Displays"), capture.sources.displays)
            sourceSection(AppLanguage.string("Applications"), capture.sources.applications)
            sourceSection(AppLanguage.string("Windows"), capture.sources.windows)
        }
        // The same switches as in Settings: both sit on the same stored values.
        Toggle(AppLanguage.string("Microphone"), isOn: $settings.microphoneEnabled)
        Toggle(AppLanguage.string("System Audio"), isOn: $settings.systemAudioEnabled)
        Divider()
        Button(AppLanguage.string("Open ClipApp")) {
            windows.showMain(.allClips)
        }
        Button(AppLanguage.string("Settings…")) {
            windows.showMain(.settings)
        }
        .keyboardShortcut(",")
        Divider()
        Button(AppLanguage.string("Quit ClipApp")) {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private func sourceSection(_ title: String, _ options: [SourceOption]) -> some View {
        if !options.isEmpty {
            Section(title) {
                ForEach(options) { option in
                    Toggle(option.title, isOn: Binding(
                        get: { settings.source == option.source },
                        set: { if $0 { settings.source = option.source } }
                    ))
                    // Another source can have another size, which would end the recording.
                    .disabled(controller.isRecording)
                }
            }
        }
    }

    private var statusText: String {
        switch capture.state {
        case .idle: return AppLanguage.string("Capture off")
        case .starting: return AppLanguage.string("Starting capture…")
        case .running(let source, _, _, let usingFallback):
            return usingFallback
                ? AppLanguage.string("\(source) · \(controller.bufferedSeconds) s buffered (selected source unavailable)")
                : AppLanguage.string("\(source) · \(controller.bufferedSeconds) s buffered")
        case .failed: return AppLanguage.string("Capture error, retrying")
        case .permissionDenied: return AppLanguage.string("No Screen Recording permission, capture stopped")
        }
    }
}
