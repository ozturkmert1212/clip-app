import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var permissions: PermissionManager
    let capture: CaptureManager

    @State private var sources: AvailableSources?

    var body: some View {
        Form {
            Section("Clip") {
                Picker("Buffer length", selection: $settings.bufferSeconds) {
                    ForEach(SettingsStore.bufferOptions, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                KeyboardShortcuts.Recorder("Clip shortcut", name: .saveClip)
            }

            Section("Video") {
                HStack {
                    Picker("Capture source", selection: $settings.source) {
                        sourceOptions
                    }
                    Button {
                        Task { await reloadSources() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh the source list")
                }
                Picker("Resolution", selection: $settings.resolution) {
                    ForEach(SettingsStore.Resolution.allCases) { Text($0.title).tag($0) }
                }
                Picker("FPS", selection: $settings.fps) {
                    ForEach(SettingsStore.fpsOptions, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                Picker("Bitrate", selection: $settings.bitrateMbps) {
                    ForEach(SettingsStore.bitrateOptions, id: \.self) { Text(verbatim: "\($0) Mbps").tag($0) }
                }
            }

            Section("Audio") {
                Toggle("System audio", isOn: $settings.systemAudioEnabled)
                levelSlider("System audio level", value: $settings.systemAudioLevel)
                    .disabled(!settings.systemAudioEnabled)
                Toggle("Microphone", isOn: $settings.microphoneEnabled)
                levelSlider("Microphone level", value: $settings.microphoneLevel)
                    .disabled(!settings.microphoneEnabled)
                if settings.microphoneEnabled, permissions.microphoneStatus != .granted {
                    HStack {
                        Text("No microphone permission; clips are saved without the microphone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(
                            permissions.microphoneStatus == .denied ? "Open System Settings" : "Allow",
                            action: permissions.requestMicrophone
                        )
                    }
                }
                Toggle("Mix audio into one track", isOn: $settings.mixAudioTracks)
                Text(settings.mixAudioTracks
                     ? "System audio and microphone are mixed into one audio track; both are heard everywhere, including Discord, VLC and browsers."
                     : "Each source gets its own audio track: system audio first, then microphone. Most players only play the first one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onChange(of: settings.microphoneEnabled) { enabled in
                if enabled, permissions.microphoneStatus == .notDetermined { permissions.requestMicrophone() }
            }

            Section("Saving") {
                LabeledContent("Folder") {
                    Text(settings.saveDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.saveDirectory.path)
                    Button("Choose…", action: chooseDirectory)
                }
                TextField("File name", text: $settings.fileNameFormat)
                Text("Example: \(settings.clipFileName(source: String(localized: "Display"))).mp4\n{date}, {time} and {source} can be used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Picker("Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                if settings.language != AppLanguage.launched {
                    HStack {
                        Text("The language changes after ClipApp restarts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart", action: permissions.relaunch)
                    }
                }
                Toggle("Show a brief on-screen message", isOn: $settings.showHUD)
                Picker("Message corner", selection: $settings.hudCorner) {
                    ForEach(HUD.Corner.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!settings.showHUD)
                Text("Appears in the chosen corner for a few seconds when a clip is saved or something goes wrong; it never ends up in clips. A system notification is sent as well.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                // Switching it off stays possible from anywhere.
                .disabled(!settings.runsFromApplications && !settings.launchAtLogin)
                if !settings.runsFromApplications {
                    Text("For this option, copy ClipApp to the /Applications folder and open it from there. It is currently running from: \(Bundle.main.bundlePath)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 820)
        // The window is reused, so the list is refreshed whenever it comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Also picks up a microphone permission flipped in System Settings.
            permissions.refresh()
            Task { await reloadSources() }
        }
    }

    @ViewBuilder
    private var sourceOptions: some View {
        if let sources {
            // A saved window or app that is gone still needs a row to select.
            if !sources.contains(settings.source) {
                Text("Unavailable (capturing the main display)").tag(settings.source)
            }
            Section("Displays") {
                ForEach(sources.displays) { Text($0.title).tag($0.source) }
            }
            if !sources.applications.isEmpty {
                Section("Applications") {
                    ForEach(sources.applications) { Text($0.title).tag($0.source) }
                }
            }
            if !sources.windows.isEmpty {
                Section("Windows") {
                    ForEach(sources.windows) { Text($0.title).tag($0.source) }
                }
            }
        } else {
            Text("Loading…").tag(settings.source)
        }
    }

    private func levelSlider(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: SettingsStore.audioLevelRange, step: 0.05)
                .labelsHidden()
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func reloadSources() async {
        sources = await capture.availableSources()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url
        }
    }
}
