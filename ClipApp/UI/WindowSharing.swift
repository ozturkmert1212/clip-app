import AppKit

/// Keeps the `sharingType` of ClipApp's windows in line with
/// `SettingsStore.showClipAppInCaptures`: `.readOnly` while ClipApp is shown in
/// captures, `.none` otherwise. Windows that must never be captured (the HUD)
/// are left alone at `.none`. Windows that open later (sheets, alerts, open
/// panels) get the value when they come on screen. Recent ScreenCaptureKit
/// ignores `sharingType`; the content filter in `CaptureManager` is what
/// actually decides, this keeps other capture tools in step with it.
@MainActor
final class WindowSharing {
    private let neverShared: Set<Int>
    private var shareable: Bool?
    private var observers: [NSObjectProtocol] = []

    init(neverShared: [CGWindowID]) {
        self.neverShared = Set(neverShared.map { Int($0) })
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.apply(to: window) }
            })
        }
    }

    func setShareable(_ shareable: Bool) {
        guard shareable != self.shareable else { return }
        self.shareable = shareable
        NSApp.windows.forEach(apply)
    }

    private func apply(to window: NSWindow) {
        guard let shareable, !neverShared.contains(window.windowNumber) else { return }
        let type: NSWindow.SharingType = shareable ? .readOnly : .none
        if window.sharingType != type { window.sharingType = type }
    }
}
