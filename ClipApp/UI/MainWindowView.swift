import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case clips, settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .clips: return "Clips"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .clips: return "film.stack"
        case .settings: return "gearshape"
        }
    }
}

/// Which tab the main window shows; the menu switches it from outside.
@MainActor
final class MainNavigation: ObservableObject {
    @Published var tab: MainTab = .clips
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
            List(selection: Binding<MainTab?>(
                get: { navigation.tab },
                set: { if let tab = $0 { navigation.tab = tab } }
            )) {
                ForEach(MainTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
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
                switch navigation.tab {
                case .clips:
                    ClipsView(library: library)
                case .settings:
                    SettingsView(settings: settings, permissions: permissions, capture: capture)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Capture state, how much is buffered and the same action as the shortcut.
private struct CaptureStatusView: View {
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: ClipController
    @ObservedObject var capture: CaptureManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.callout)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Buffer: \(controller.bufferedSeconds) of \(settings.bufferSeconds) s")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                controller.saveClip()
            } label: {
                Text(controller.isSaving
                     ? String(localized: "Saving Clip…")
                     : String(localized: "Save Last \(settings.bufferSeconds) Seconds"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(controller.isSaving)
        }
        .padding([.horizontal, .bottom], 12)
    }

    private var statusColor: Color {
        guard permissions.screenRecordingGranted else { return .red }
        switch capture.state {
        case .running: return .green
        case .starting: return .yellow
        case .idle: return .secondary
        case .failed, .permissionDenied: return .red
        }
    }

    private var statusText: String {
        guard permissions.screenRecordingGranted else { return String(localized: "Screen Recording permission required") }
        switch capture.state {
        case .idle: return String(localized: "Capture off")
        case .starting: return String(localized: "Starting capture…")
        case .running(let source, _, _, _): return String(localized: "Capturing · \(source)")
        case .failed: return String(localized: "Capture error, retrying")
        case .permissionDenied: return String(localized: "No Screen Recording permission, capture stopped")
        }
    }
}
