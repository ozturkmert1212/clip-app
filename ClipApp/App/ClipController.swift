import AppKit
import Combine
import CoreMedia
import OSLog

/// Wires capture -> encoder -> ring buffer, feeds system audio and microphone
/// into the same buffer, and turns a hotkey press into a clip.
@MainActor
final class ClipController: ObservableObject {
    enum SaveResult {
        case saved(URL)
        case failed(String)
    }

    @Published private(set) var isSaving = false
    @Published private(set) var lastResult: SaveResult?
    /// Set while the ring buffer's byte limit keeps it shorter than the
    /// configured duration: the seconds it currently reaches back.
    @Published private(set) var byteLimitedSeconds: Int?
    /// How far back a clip saved right now would reach, for the status strip.
    @Published private(set) var bufferedSeconds = 0

    let capture: CaptureManager

    private let settings: SettingsStore
    private let permissions: PermissionManager
    private let ringBuffer: RingBuffer
    private let encoder: EncoderPipeline
    private let systemAudio: AudioPipeline
    private let microphoneAudio: AudioPipeline
    private let microphone: MicrophoneCapture
    private var hotkeys: HotkeyManager?
    private let notifier = Notifier()
    private let hud = HUD()
    private let logger = Logger(subsystem: "com.mertozturk.ClipApp", category: "clip")
    private var outageTask: Task<Void, Never>?
    private var reportedFallback = false
    private var lastFailure = ""
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore, permissions: PermissionManager) {
        let ringBuffer = RingBuffer(
            duration: TimeInterval(settings.bufferSeconds),
            byteLimit: settings.bufferByteLimit
        )
        let encoder = EncoderPipeline(fps: settings.fps, bitrate: settings.bitrate) { ringBuffer.append($0) }
        let systemAudio = AudioPipeline { ringBuffer.append($0, to: .system) }
        let microphoneAudio = AudioPipeline { ringBuffer.append($0, to: .microphone) }
        self.settings = settings
        self.permissions = permissions
        self.ringBuffer = ringBuffer
        self.encoder = encoder
        self.systemAudio = systemAudio
        self.microphoneAudio = microphoneAudio
        capture = CaptureManager(
            onVideoFrame: { encoder.encode($0) },
            onAudioSample: { systemAudio.process($0) }
        )
        microphone = MicrophoneCapture { microphoneAudio.process($0, at: $1) }
        capture.excludedWindowIDs = [hud.windowID]
        applySettings()
        hotkeys = HotkeyManager { [weak self] in self?.saveClip() }

        // `objectWillChange` fires before the new value is stored, hence the hop.
        // The microphone depends on its permission as well as on the setting.
        settings.objectWillChange
            .merge(with: permissions.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applySettings() }
            .store(in: &cancellables)
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let status = self.ringBuffer.videoStatus()
                let seconds = status.isByteLimited ? Int(status.span.rounded()) : nil
                if seconds != self.byteLimitedSeconds { self.byteLimitedSeconds = seconds }
                // Measured to now, not to the newest frame: a static screen delivers none.
                let reach = status.oldest.map { (CMClockGetTime(CMClockGetHostTimeClock()) - $0).seconds } ?? 0
                let buffered = min(self.settings.bufferSeconds, max(0, Int(reach)))
                if buffered != self.bufferedSeconds { self.bufferedSeconds = buffered }
            }
            .store(in: &cancellables)
        capture.$state
            .removeDuplicates()
            .sink { [weak self] in self?.captureStateChanged($0) }
            .store(in: &cancellables)
    }

    /// Tells the user when clips are not what they expect: capture is down,
    /// or the chosen source is gone. Brief hiccups that recover stay silent.
    private func captureStateChanged(_ state: CaptureManager.State) {
        switch state {
        case .running(_, _, _, let usingFallback):
            outageTask?.cancel()
            outageTask = nil
            if usingFallback, !reportedFallback {
                report(
                    title: AppLanguage.string("Selected source not found"),
                    body: AppLanguage.string("Capturing the main display instead. This clears once the source is back or you pick another one in Settings."),
                    hudDetail: AppLanguage.string("Capturing the main display"),
                    identifier: "capture"
                )
            }
            reportedFallback = usingFallback
        case .permissionDenied:
            outageTask?.cancel()
            outageTask = nil
            report(
                title: AppLanguage.string("No Screen Recording permission"),
                body: AppLanguage.string("Capture stopped, clips can't be saved. Allow ClipApp under System Settings > Privacy & Security > Screen Recording."),
                hudDetail: AppLanguage.string("Capture stopped, clips can't be saved"),
                identifier: "capture"
            )
        case .failed(let message):
            lastFailure = message
            // Retries keep cycling through `.starting`; only `.running` ends the outage.
            guard outageTask == nil else { return }
            outageTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.report(
                    title: AppLanguage.string("Capture stopped"),
                    body: AppLanguage.string("Retrying: \(self.lastFailure)"),
                    hudDetail: AppLanguage.string("Retrying"),
                    identifier: "capture"
                )
            }
        case .idle, .starting:
            break
        }
    }

    /// A problem goes out both ways: the notification stays in Notification
    /// Center, the HUD is what is actually seen while the screen is captured.
    private func report(title: String, body: String, hudDetail: String? = nil, identifier: String) {
        notifier.show(title: title, body: body, identifier: identifier)
        if settings.showHUD { hud.show(.failure, title: title, detail: hudDetail ?? body, in: settings.hudCorner) }
    }

    /// Pushes every setting down; each component ignores values it already has.
    private func applySettings() {
        ringBuffer.setDuration(TimeInterval(settings.bufferSeconds))
        ringBuffer.setByteLimit(settings.bufferByteLimit)
        encoder.configure(fps: settings.fps, bitrate: settings.bitrate)
        capture.configuration = settings.captureConfiguration

        systemAudio.setGain(Float(settings.systemAudioLevel))
        microphoneAudio.setGain(Float(settings.microphoneLevel))
        let microphoneOn = settings.microphoneEnabled && permissions.microphoneStatus == .granted
        microphone.setEnabled(microphoneOn)
        // A source that was just switched off must not show up in the next clip.
        if !settings.systemAudioEnabled { ringBuffer.removeAudio(.system) }
        if !microphoneOn { ringBuffer.removeAudio(.microphone) }
    }

    func saveClip() {
        guard !isSaving else { return }
        // Without the permission the buffer is empty or holds stale footage.
        if capture.state == .permissionDenied || !permissions.screenRecordingGranted {
            finish(.failed(AppLanguage.string("No Screen Recording permission")))
            return
        }
        // Capture timestamps are on the host clock, so "now" is too.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard let snapshot = ringBuffer.snapshot(endingAt: now) else {
            finish(.failed(ClipWriter.WriteError.emptyBuffer.localizedDescription))
            return
        }
        var sourceName = AppLanguage.string("Display")
        if case .running(let source, _, _, _) = capture.state { sourceName = source }
        let directory = settings.saveDirectory
        let name = settings.clipFileName(source: sourceName)
        let mixAudio = settings.mixAudioTracks
        isSaving = true
        Task {
            do {
                finish(.saved(try await ClipWriter.write(snapshot, to: directory, name: name, mixAudio: mixAudio)))
            } catch {
                finish(.failed(error.localizedDescription))
            }
        }
    }

    func openClipDirectory() {
        try? FileManager.default.createDirectory(at: settings.saveDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.saveDirectory)
    }

    private func finish(_ result: SaveResult) {
        isSaving = false
        lastResult = result
        switch result {
        case .saved(let url):
            logger.notice("Clip saved: \(url.path, privacy: .public)")
            NSSound(named: "Glass")?.play()
            notifier.clipSaved(url)
            if settings.showHUD {
                hud.show(.success, title: AppLanguage.string("Clip saved"), detail: url.lastPathComponent, in: settings.hudCorner)
            }
        case .failed(let message):
            logger.error("Clip failed: \(message, privacy: .public)")
            NSSound.beep()
            report(title: AppLanguage.string("Couldn't save clip"), body: message, identifier: "clipFailed")
        }
    }
}
