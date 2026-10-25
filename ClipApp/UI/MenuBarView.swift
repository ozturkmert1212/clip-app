import SwiftUI

/// The menu bar menu: the controls that are wanted in the middle of a game.
/// Everything that is a preference lives in the Settings tab.
struct MenuBarView: View {
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: ClipController
    @ObservedObject var capture: CaptureManager
    @ObservedObject var updates: UpdateController
    let windows: WindowManager

    // Menu items are AppKit in the end, so every title is looked up in the
    // chosen language here instead of relying on the environment.
    var body: some View {
        // Found by a scheduled check while the user was elsewhere; leads to Sparkle's window.
        if let version = updates.availableUpdate {
            Button(AppLanguage.string("Update available: ClipApp \(version)…")) { updates.showUpdate() }
            Divider()
        }
        // A missing permission takes the place of the status and leads to where it is fixed.
        if !permissions.screenRecordingGranted {
            Button(AppLanguage.string("Screen Recording permission needed")) { windows.showMain(.settings) }
        } else {
            // The same dot as in the window: indigo while capturing, red while recording.
            Label {
                Text(verbatim: statusText)
            } icon: {
                Image(nsImage: status.menuImage)
            }
            if settings.microphoneEnabled, permissions.microphoneStatus != .granted {
                Button(AppLanguage.string("Microphone permission needed")) { windows.showMain(.settings) }
            }
        }
        Divider()
        // The same choice as in the window: start clipping, or save and stop once it is on.
        switch controller.activity.primaryAction {
        case .startClipping:
            Button(AppLanguage.string("Start Clipping")) { controller.startClipping() }
        case .saveClip:
            Button(controller.isSaving
                   ? AppLanguage.string("Saving Clip…")
                   : AppLanguage.string("Save Last \(settings.bufferSeconds) Seconds")) {
                controller.saveClip()
            }
            .disabled(controller.isSaving)
        }
        if controller.activity.offersStopClipping {
            Button(AppLanguage.string("Stop Clipping")) { controller.stopClipping() }
        }
        Button(controller.recordingSeconds.map { AppLanguage.string("Stop Recording (\(ClipFormat.duration(TimeInterval($0))))") }
               ?? AppLanguage.string("Start Recording")) {
            controller.toggleRecording()
        }
        .disabled(controller.isStartingRecording)
        Divider()
        Menu(AppLanguage.string("Source")) {
            Text(verbatim: controller.isRecording
                 ? AppLanguage.string("The source can't be changed during a recording.")
                 : controller.activity.streamRuns
                 ? AppLanguage.string("Changing the source restarts capture and clears the replay buffer.")
                 : AppLanguage.string("The source is used once clipping or a recording starts."))
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
        Button(AppLanguage.string("Check for Updates…")) {
            updates.checkForUpdates()
        }
        .disabled(!updates.canCheckForUpdates)
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

    private var status: Brand.Status {
        if controller.isRecording { return .recording }
        guard controller.activity.streamRuns else { return .idle }
        switch capture.state {
        case .running: return .capturing
        case .starting, .idle: return .idle
        case .failed, .permissionDenied: return .problem
        }
    }

    private var statusText: String {
        guard controller.activity.streamRuns else { return AppLanguage.string("Clipping off") }
        switch capture.state {
        case .idle, .starting: return AppLanguage.string("Starting capture…")
        case .running(let source, _, _, let usingFallback):
            // Running for a recording alone.
            guard controller.isClipping else { return AppLanguage.string("Recording · \(source)") }
            return usingFallback
                ? AppLanguage.string("Clipping · \(source) · \(controller.bufferedSeconds) s buffered (selected source unavailable)")
                : AppLanguage.string("Clipping · \(source) · \(controller.bufferedSeconds) s buffered")
        case .failed: return AppLanguage.string("Capture error, retrying")
        case .permissionDenied: return AppLanguage.string("No Screen Recording permission, capture stopped")
        }
    }
}
