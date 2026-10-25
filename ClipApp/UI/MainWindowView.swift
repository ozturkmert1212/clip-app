import SwiftUI

/// What the sidebar can show in the detail area.
enum SidebarItem: Hashable {
    case allClips
    case game(String)
    /// Clips from before the folder layout.
    case other
    case videos
    case settings
}

/// The sidebar selection; the menu switches it from outside.
@MainActor
final class MainNavigation: ObservableObject {
    @Published var selection: SidebarItem = .allClips
    /// Counts requests to show Settings; each one shows it from the top.
    @Published var settingsVisit = 0
}

struct MainWindowView: View {
    @ObservedObject var navigation: MainNavigation
    let settings: SettingsStore
    let permissions: PermissionManager
    let controller: ClipController
    let capture: CaptureManager
    let updates: UpdateController
    let library: ClipLibrary

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(navigation: navigation, library: library, updates: updates) {
                CaptureStatusView(
                    permissions: permissions,
                    settings: settings,
                    controller: controller,
                    capture: capture
                )
            }
            .frame(width: 220)

            Divider()

            Group {
                if navigation.selection == .settings {
                    SettingsView(settings: settings, permissions: permissions, capture: capture, updates: updates)
                        .id(navigation.settingsVisit)
                } else {
                    ClipsView(library: library, settings: settings, filter: navigation.selection)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Clips by game and the recordings on top; Settings and the capture status
/// pinned to the bottom. The list is an ordinary selectable list: arrow keys
/// move the selection and VoiceOver announces it. Its highlight is drawn by
/// AppKit in the app's accent color (see `Brand.fill`).
private struct Sidebar<Status: View>: View {
    @ObservedObject var navigation: MainNavigation
    @ObservedObject var library: ClipLibrary
    @ObservedObject var updates: UpdateController
    @ViewBuilder let status: () -> Status

    @FocusState private var isListFocused: Bool
    @State private var keyMonitor: Any?

    var body: some View {
        // Settings sits below the list, so for the list it is "nothing selected".
        List(selection: Binding<SidebarItem?>(
            get: { navigation.selection == .settings ? nil : navigation.selection },
            set: { if let item = $0 { navigation.selection = item } }
        )) {
            Section("Clips") {
                row(.allClips, count: library.clips.count) {
                    Text("All Clips")
                } icon: {
                    Image(systemName: "film.stack")
                }
                ForEach(library.games) { game in
                    row(.game(game.name), count: game.count) {
                        Text(verbatim: game.name)
                    } icon: {
                        GameIcon(bundleID: game.bundleID)
                    }
                }
                if library.otherCount > 0 {
                    row(.other, count: library.otherCount) {
                        Text("Other")
                    } icon: {
                        Image(systemName: "tray")
                    }
                }
            }
            Section("Videos") {
                row(.videos, count: library.videos.count) {
                    Text("Recordings")
                } icon: {
                    Image(systemName: "video")
                }
            }
        }
        .listStyle(.sidebar)
        .focused($isListFocused)
        // A game whose last clip was moved or deleted has no row left to sit on.
        .onChange(of: library.games) { games in
            if case .game(let name) = navigation.selection, !games.contains(where: { $0.name == name }) {
                navigation.selection = .allClips
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let version = updates.availableUpdate {
                    updateNotice(version)
                }
                settingsRow
                status()
            }
        }
        .onAppear(perform: startKeyMonitor)
        .onDisappear(perform: stopKeyMonitor)
    }

    private func row<Title: View, Icon: View>(
        _ item: SidebarItem, count: Int?,
        @ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon
    ) -> some View {
        SidebarLabel(isSelected: navigation.selection == item, count: count, title: title(), icon: icon())
            .tag(item)
    }

    /// A scheduled check found an update while the user was elsewhere; the
    /// click shows it in Sparkle's window. Gone once the user has seen it there.
    private func updateNotice(_ version: String) -> some View {
        Button(action: updates.showUpdate) {
            HStack(alignment: .firstTextBaseline, spacing: Brand.Space.one) {
                Image(systemName: "arrow.down.circle.fill")
                Text("Update available · \(version)")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(NoticeButtonStyle())
        .padding(.horizontal, Brand.Space.one)
        .padding(.bottom, Brand.Space.one)
    }

    /// Looks and reads like a row of the list above it, and is one more stop
    /// for the arrow keys (see `startKeyMonitor`).
    private var settingsRow: some View {
        let isSelected = navigation.selection == .settings
        return Button {
            navigation.selection = .settings
        } label: {
            SidebarLabel(
                isSelected: isSelected, followsListHighlight: false, count: nil,
                title: Text("Settings"), icon: Image(systemName: "gearshape")
            )
                .padding(.horizontal, Brand.Space.one)
                .padding(.vertical, Brand.Space.one - 2)
                .background(
                    isSelected ? Brand.fill : Color.clear,
                    in: RoundedRectangle(cornerRadius: Brand.Radius.row, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .padding(.horizontal, Brand.Space.one)
        .padding(.bottom, Brand.Space.one)
    }

    /// The rows the arrow keys walk through, top to bottom, ending with Settings.
    private var order: [SidebarItem] {
        var items: [SidebarItem] = [.allClips] + library.games.map { .game($0.name) }
        if library.otherCount > 0 { items.append(.other) }
        return items + [.videos, .settings]
    }

    /// The list handles the arrow keys itself, but it ends at its last row.
    /// This carries Down on from there to Settings and Up back from it, so
    /// the whole sidebar is one run for the keyboard.
    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let down: UInt16 = 125, up: UInt16 = 126
            guard isListFocused, event.keyCode == down || event.keyCode == up,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            let items = order
            guard let index = items.firstIndex(of: navigation.selection) else { return event }
            if event.keyCode == down, index >= items.count - 2 {
                // On the list's last row: step down to Settings. On Settings: nothing below.
                navigation.selection = .settings
                return nil
            }
            if event.keyCode == up, navigation.selection == .settings {
                navigation.selection = items[items.count - 2]
                return nil
            }
            return event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// Icon, title and count of one sidebar entry. On a highlighted row
/// everything turns white, as the system's own labels do.
private struct SidebarLabel<Title: View, Icon: View>: View {
    let isSelected: Bool
    /// Rows of the list take their cue from the list's highlight, which
    /// goes gray when the list loses focus; the Settings row draws its own.
    var followsListHighlight = true
    let count: Int?
    let title: Title
    let icon: Icon

    var body: some View {
        if #available(macOS 14.0, *), followsListHighlight {
            ProminenceReader { content(isHighlighted: $0) }
        } else {
            // macOS 13 does not say whether the highlight is the strong one.
            content(isHighlighted: isSelected)
        }
    }

    private func content(isHighlighted: Bool) -> some View {
        HStack(spacing: Brand.Space.one) {
            icon
                .foregroundStyle(isHighlighted ? Color.white : Brand.accentText)
                .frame(width: 20)
            title
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Brand.Space.half)
            if let count {
                Text(verbatim: "\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
    }
}

/// Whether the row this sits in currently has the strong selection highlight.
@available(macOS 14.0, *)
private struct ProminenceReader<Content: View>: View {
    @Environment(\.backgroundProminence) private var prominence
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        content(prominence == .increased)
    }
}

/// The icon of the app a game's clips were recorded in, if it is installed;
/// a plain film frame otherwise.
struct GameIcon: View {
    let bundleID: String?

    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let image = Self.image(for: bundleID) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "film")
        }
    }

    private static func image(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}

/// Capture state, how much is buffered, and the actions that are also on
/// the shortcuts: starting clipping or, once it is on, saving a clip and
/// stopping it again; starting or stopping a recording.
private struct CaptureStatusView: View {
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: ClipController
    @ObservedObject var capture: CaptureManager

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.Space.one) {
            Divider()
            VStack(alignment: .leading, spacing: Brand.Space.half) {
                HStack(alignment: .firstTextBaseline, spacing: Brand.Space.one) {
                    indicator
                    Text(verbatim: headline)
                        .font(.callout)
                        .monospacedDigit()
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // During a recording the headline is the recording; clipping moves down here.
                if controller.isRecording {
                    Text(verbatim: captureText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let seconds = controller.byteLimitedSeconds {
                    Text("Memory cap active: content exceeds the target bitrate, keeping the last ~\(seconds) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            switch controller.activity.primaryAction {
            case .startClipping:
                Button {
                    controller.startClipping()
                } label: {
                    Text("Start Clipping")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            case .saveClip:
                Button {
                    controller.saveClip()
                } label: {
                    Text(controller.isSaving
                         ? AppLanguage.string("Saving Clip…")
                         : AppLanguage.string("Save Last \(settings.bufferSeconds) Seconds"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(controller.isSaving)
                Button {
                    controller.stopClipping()
                } label: {
                    // A title that does not fit wraps rather than being cut off.
                    Text("Stop Clipping")
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(NeutralButtonStyle())
            }
            Button {
                controller.toggleRecording()
            } label: {
                HStack(spacing: Brand.Space.one) {
                    if let seconds = controller.recordingSeconds {
                        RecordDot(onRed: true)
                        Text("Stop Recording")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text(verbatim: ClipFormat.duration(TimeInterval(seconds)))
                            .monospacedDigit()
                    } else {
                        Image(systemName: "record.circle")
                        Text("Start Recording")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RecordingButtonStyle(isRecording: controller.isRecording))
            .disabled(controller.isStartingRecording)
        }
        .padding([.horizontal, .bottom], Brand.Space.two - Brand.Space.half)
    }

    /// A dot for the states that are fine, a warning sign for the ones that
    /// are not, so the difference does not hang on color alone.
    @ViewBuilder
    private var indicator: some View {
        switch status {
        case .recording:
            RecordDot()
        case .problem:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(status.color)
        case .capturing, .idle:
            Circle()
                .fill(status.color)
                .frame(width: Brand.dotSize, height: Brand.dotSize)
        }
    }

    private var status: Brand.Status {
        guard permissions.screenRecordingGranted else { return .problem }
        if controller.isRecording { return .recording }
        guard controller.activity.streamRuns else { return .idle }
        switch capture.state {
        case .running: return .capturing
        case .starting, .idle: return .idle
        case .failed, .permissionDenied: return .problem
        }
    }

    private var headline: String {
        if let seconds = controller.recordingSeconds, permissions.screenRecordingGranted {
            return AppLanguage.string("Recording · \(ClipFormat.duration(TimeInterval(seconds)))")
        }
        return captureText
    }

    private var captureText: String {
        guard permissions.screenRecordingGranted else { return AppLanguage.string("Screen Recording permission required") }
        guard controller.activity.streamRuns else { return AppLanguage.string("Clipping off") }
        switch capture.state {
        case .idle, .starting: return AppLanguage.string("Starting capture…")
        case .running(let source, _, _, _):
            return controller.isClipping
                ? AppLanguage.string("Clipping · \(source) · \(controller.bufferedSeconds) s buffered")
                : AppLanguage.string("Clipping off")
        case .failed: return AppLanguage.string("Capture error, retrying")
        case .permissionDenied: return AppLanguage.string("No Screen Recording permission, capture stopped")
        }
    }
}
