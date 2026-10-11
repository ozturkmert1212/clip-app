import Combine
import SwiftUI

struct PermissionView: View {
    @ObservedObject var permissions: PermissionManager

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("ClipApp needs permission to work")
                .font(.title2.bold())

            PermissionRow(
                icon: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                detail: "Required. To capture the screen and keep the last seconds in memory.",
                granted: permissions.screenRecordingGranted,
                actionTitle: "Allow",
                action: permissions.requestScreenRecording
            )

            PermissionRow(
                icon: "mic",
                title: "Microphone",
                detail: "Optional. To add your own voice to clips.",
                granted: permissions.microphoneStatus == .granted,
                actionTitle: permissions.microphoneStatus == .denied ? "Open System Settings" : "Allow",
                action: permissions.requestMicrophone
            )

            PermissionRow(
                icon: "bell",
                title: "Notifications",
                detail: "Optional. To tell you when a clip is saved or something goes wrong.",
                granted: permissions.notificationStatus == .granted,
                actionTitle: permissions.notificationStatus == .denied ? "Open System Settings" : "Allow",
                action: permissions.requestNotifications,
                note: "If no banner shows up: macOS hides banners because ClipApp captures the screen all the time. Turn on \"Allow notifications when mirroring or sharing the display\" at the top of the Notifications page.",
                noteActionTitle: "Open Notification Settings",
                noteAction: permissions.openNotificationSettings
            )

            Divider()

            HStack {
                Text("After turning on Screen Recording, restart ClipApp for the change to take effect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Restart", action: permissions.relaunch)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onReceive(poll) { _ in permissions.refresh() }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let granted: Bool
    let actionTitle: LocalizedStringKey
    let action: () -> Void
    var note: LocalizedStringKey?
    var noteActionTitle: LocalizedStringKey = ""
    var noteAction: () -> Void = {}

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    Button(noteActionTitle, action: noteAction)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
            }
        }
    }
}
