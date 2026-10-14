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
    let library: ClipLibrary

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(navigation: navigation, library: library) {
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
                    SettingsView(settings: settings, permissions: permissions, capture: capture)
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
/// pinned to the bottom. The rows draw their own selection, so it is indigo
/// whatever accent color the system is set to.
private struct Sidebar<Status: View>: View {
    @ObservedObject var navigation: MainNavigation
    @ObservedObject var library: ClipLibrary
    @ViewBuilder let status: () -> Status

    var body: some View {
        List {
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
        // A game whose last clip was moved or deleted has no row left to sit on.
        .onChange(of: library.games) { games in
            if case .game(let name) = navigation.selection, !games.contains(where: { $0.name == name }) {
                navigation.selection = .allClips
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                row(.settings, count: nil) {
                    Text("Settings")
                } icon: {
                    Image(systemName: "gearshape")
                }
                .padding(.horizontal, Brand.Space.one)
                .padding(.bottom, Brand.Space.one)
                status()
            }
        }
    }

    private func row<Title: View, Icon: View>(
        _ item: SidebarItem, count: Int?,
        @ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon
    ) -> some View {
        SidebarRow(isSelected: navigation.selection == item, count: count, title: title(), icon: icon()) {
            navigation.selection = item
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
    }
}

private struct SidebarRow<Title: View, Icon: View>: View {
    let isSelected: Bool
    let count: Int?
    let title: Title
    let icon: Icon
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Brand.Space.one) {
                icon
                    .foregroundStyle(isSelected ? Color.white : Brand.accentText)
                    .frame(width: 20)
                title
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Brand.Space.half)
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
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

/// Capture state, how much is buffered, and the two actions that are also
/// on the shortcuts: saving a clip and starting or stopping a recording.
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
                // During a recording the headline is the recording; the source moves down here.
                if controller.isRecording {
                    Text(verbatim: captureText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Buffer: \(controller.bufferedSeconds) of \(settings.bufferSeconds) s")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let seconds = controller.byteLimitedSeconds {
                    Text("Memory cap active: content exceeds the target bitrate, keeping the last ~\(seconds) s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
        switch capture.state {
        case .idle: return AppLanguage.string("Capture off")
        case .starting: return AppLanguage.string("Starting capture…")
        case .running(let source, _, _, _): return AppLanguage.string("Capturing · \(source)")
        case .failed: return AppLanguage.string("Capture error, retrying")
        case .permissionDenied: return AppLanguage.string("No Screen Recording permission, capture stopped")
        }
    }
}
