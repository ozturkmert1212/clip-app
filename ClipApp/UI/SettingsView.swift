import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var permissions: PermissionManager
    let capture: CaptureManager

    @State private var sources: AvailableSources?

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    detail: "Required. To capture the screen and keep the last seconds in memory.",
                    status: permissions.screenRecordingStatus,
                    action: permissions.requestScreenRecording
                ) {
                    // A running app keeps seeing the old answer.
                    if permissions.screenRecordingStatus == .denied {
                        Text("ClipApp only sees this permission after a restart: turn it on in System Settings, then restart.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Restart ClipApp", action: permissions.relaunch)
                            .controlSize(.small)
                    }
                }
                PermissionRow(
                    icon: "mic",
                    title: "Microphone",
                    detail: "Optional. To add your own voice to clips.",
                    status: permissions.microphoneStatus,
                    action: permissions.requestMicrophone
                ) {}
                PermissionRow(
                    icon: "bell",
                    title: "Notifications",
                    detail: "Optional. To tell you when a clip is saved or something goes wrong.",
                    status: permissions.notificationStatus,
                    action: permissions.requestNotifications
                ) {
                    Text("If no banner shows up: macOS hides banners because ClipApp captures the screen all the time. Turn on \"Allow notifications when mirroring or sharing the display\" at the top of the Notifications page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Notification Settings", action: permissions.openNotificationSettings)
                        .controlSize(.small)
                }
            }

            Section("Clip") {
                Picker("Buffer length", selection: $settings.bufferSeconds) {
                    ForEach(SettingsStore.bufferOptions, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                KeyboardShortcuts.Recorder("Clip shortcut", name: .saveClip)
                KeyboardShortcuts.Recorder("Recording shortcut", name: .toggleRecording)
            }

            Section("Video") {
                HStack {
                    Picker("Capture source", selection: $settings.source) {
                        sourceOptions
                    }
                    .id(settings.language)
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
                // Titles that are plain strings only reach the pop-up menu
                // when it is rebuilt, hence the identity tied to the language.
                .id(settings.language)
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
                Toggle("Keep separate audio tracks for editing", isOn: $settings.keepAudioStems)
                Text(settings.keepAudioStems
                     ? "Every player uses the mixed track. Game audio and microphone are also stored as separate, disabled tracks, so their levels can be changed in the editor. Adds about 1.4 MB per 30 seconds."
                     : "Clips only get the mixed track. Game audio and microphone can't be adjusted separately afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Saving") {
                LabeledContent("Folder") {
                    Text(settings.saveDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(settings.saveDirectory.path)
                    Button("Choose…", action: chooseDirectory)
                }
                Picker("When saving an edited clip", selection: $settings.editSaveMode) {
                    ForEach(SettingsStore.EditSaveMode.allCases) { Text($0.title).tag($0) }
                }
                .id(settings.language)
            }

            Section("General") {
                Picker("Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                if settings.language != AppLanguage.launched {
                    HStack {
                        Text("Text supplied by macOS, such as the app menu and the shortcut field, changes after ClipApp restarts.")
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
                .id(settings.language)
                .disabled(!settings.showHUD)
                Text("Appears in the chosen corner for a few seconds when a clip is saved or something goes wrong; it never ends up in clips. A system notification is sent as well.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show ClipApp in recordings", isOn: $settings.showClipAppInCaptures)
                Text("ClipApp's own windows and menu appear in clips and recordings. The brief on-screen message never does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Start clipping when ClipApp opens", isOn: $settings.startClippingAtLaunch)
                Toggle("Open window at launch", isOn: $settings.openWindowAtLaunch)
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                // Switching it off stays possible from anywhere.
                .disabled(!settings.runsFromApplications && !settings.launchAtLogin)
                if !settings.runsFromApplications {
                    Text("For this option, copy ClipApp to the /Applications folder and open it from there. It is currently running from: \(Bundle.main.bundlePath)")
                        .font(.caption)
                        .foregroundStyle(Brand.warning)
                }
                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Brand.failure)
                }
            }

            aboutSection
        }
        .formStyle(.grouped)
        .task { await reloadSources() }
        // The source list holds finished titles.
        .onChange(of: settings.language) { _ in
            Task { await reloadSources() }
        }
        // The window is reused, so the list is refreshed whenever it comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Also picks up a microphone permission flipped in System Settings.
            permissions.refresh()
            Task { await reloadSources() }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            HStack(spacing: Brand.Space.two) {
                BrandBadge()
                VStack(alignment: .leading, spacing: Brand.Space.half) {
                    Text(verbatim: "ClipApp")
                        .font(.headline)
                    Text("Version \(Self.version) (\(Self.build))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, Brand.Space.half)
        }
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

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
        panel.prompt = AppLanguage.string("Choose")
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectory = url
        }
    }
}

/// One permission: what it is for, where it stands right now, and the one
/// thing that can be done about it.
private struct PermissionRow<Extra: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let status: PermissionManager.Status
    let action: () -> Void
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        HStack(alignment: .top, spacing: Brand.Space.two) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: Brand.Space.half) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                extra()
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: Brand.Space.one) {
                switch status {
                case .granted:
                    Label("Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Brand.success)
                case .denied:
                    Label("Not granted", systemImage: "xmark.circle.fill")
                        .foregroundStyle(Brand.warning)
                    // The system only asks once; after that the switch is there.
                    Button("Open System Settings", action: action)
                case .notDetermined:
                    Label("Not determined", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                    Button("Request", action: action)
                }
            }
            .font(.callout)
        }
        .padding(.vertical, Brand.Space.half)
    }
}
