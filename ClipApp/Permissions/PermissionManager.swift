import AVFoundation
import AppKit
import CoreGraphics
import UserNotifications

@MainActor
final class PermissionManager: ObservableObject {
    enum Status {
        case notDetermined, granted, denied
    }
    typealias MicrophoneStatus = Status
    typealias NotificationStatus = Status

    @Published private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    /// The system has no "not asked yet" for Screen Recording, so the app
    /// remembers whether it asked.
    @Published private(set) var screenRecordingRequested = UserDefaults.standard.bool(forKey: PermissionManager.screenRequestedKey)
    @Published private(set) var microphoneStatus = PermissionManager.currentMicrophoneStatus()
    /// Unknown until the first asynchronous check comes back.
    @Published private(set) var notificationStatus: NotificationStatus = .notDetermined

    private static let screenRequestedKey = "hasRequestedScreenRecording"
    private var poll: Timer?
    private var activation: NSObjectProtocol?

    /// Without the permission and after asking, the switch may already be on
    /// in System Settings: a running process keeps seeing the old answer.
    var screenRecordingStatus: Status {
        screenRecordingGranted ? .granted : (screenRecordingRequested ? .denied : .notDetermined)
    }

    init() {
        // Permissions can be granted or revoked in System Settings at any time:
        // checked when the user comes back to the app, and on a timer.
        refresh()
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let screen = CGPreflightScreenCaptureAccess()
        if screen != screenRecordingGranted { screenRecordingGranted = screen }
        let microphone = Self.currentMicrophoneStatus()
        if microphone != microphoneStatus { microphoneStatus = microphone }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: NotificationStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional: status = .granted
            case .notDetermined: status = .notDetermined
            default: status = .denied
            }
            Task { @MainActor in
                if status != self.notificationStatus { self.notificationStatus = status }
            }
        }
    }

    func requestNotificationsIfUndetermined() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            Task { @MainActor in self.requestNotifications() }
        }
    }

    /// Optional: without it clips are still saved, only the banner is missing.
    /// The system only asks once; after that the switch is in System Settings.
    func requestNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in
                    Task { @MainActor in self.refresh() }
                }
            } else {
                Task { @MainActor in self.openNotificationSettings() }
            }
        }
    }

    /// The Notifications page of System Settings. The switch that allows
    /// banners while the screen is shared lives there and has no API.
    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The system prompt only appears once per app; after that the user has to
    /// flip the switch in System Settings themselves.
    func requestScreenRecording() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.screenRequestedKey) {
            openSettings(pane: "Privacy_ScreenCapture")
        } else {
            defaults.set(true, forKey: Self.screenRequestedKey)
            screenRecordingRequested = true
            CGRequestScreenCaptureAccess()
        }
        refresh()
    }

    func requestMicrophone() {
        switch microphoneStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in self.refresh() }
            }
        case .denied:
            openSettings(pane: "Privacy_Microphone")
        case .granted:
            break
        }
    }

    /// Screen Recording changes only take effect in a fresh process.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func openSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func currentMicrophoneStatus() -> MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}
