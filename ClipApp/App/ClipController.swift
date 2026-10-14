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
    /// How long the running recording has been going; `nil` when there is none.
    @Published private(set) var recordingSeconds: Int?

    let capture: CaptureManager

    private let settings: SettingsStore
    private let permissions: PermissionManager
    private let ringBuffer: RingBuffer
    private let encoder: EncoderPipeline
    private let systemAudio: AudioPipeline
    private let microphoneAudio: AudioPipeline
    private let microphone: MicrophoneCapture
    private var hotkeys: HotkeyManager?
    /// Where the pipeline's output is copied to while a recording runs.
    private let recording = RecordingTap()
    private var recordingStart: Date?
    private var isEndingRecording = false
    private let notifier = Notifier()
    private let games = GameTracker()
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
        // The replay buffer keeps filling during a recording; the recording
        // gets the same samples on the side.
        let recording = self.recording
        let encoder = EncoderPipeline(fps: settings.fps, bitrate: settings.bitrate) {
            ringBuffer.append($0)
            recording.writer?.appendVideo($0)
        }
        let systemAudio = AudioPipeline {
            ringBuffer.append($0, to: .system)
            recording.writer?.appendAudio($0, from: .system)
        }
        let microphoneAudio = AudioPipeline {
            ringBuffer.append($0, to: .microphone)
            recording.writer?.appendAudio($0, from: .microphone)
        }
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
        hotkeys = HotkeyManager(
            onSaveClip: { [weak self] in self?.saveClip() },
            onToggleRecording: { [weak self] in self?.toggleRecording() }
        )

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
                if let start = self.recordingStart {
                    self.recordingSeconds = Int(Date().timeIntervalSince(start))
                }
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
        // Filed under the app in front right now (not when the write finishes),
        // or the one that was in front during the clip if ClipApp is now.
        let game = games.current(within: TimeInterval(settings.bufferSeconds))
        let directory = settings.clipsDirectory.appendingPathComponent(game.name, isDirectory: true)
        let info = ClipInfo(game: game.name, bundleID: game.bundleID, recorded: Date())
        let name = settings.clipFileName(source: sourceName)
        let keepStems = settings.keepAudioStems
        isSaving = true
        Task {
            do {
                finish(.saved(try await ClipWriter.write(snapshot, to: directory, name: name, keepStems: keepStems, info: info)))
            } catch {
                finish(.failed(error.localizedDescription))
            }
        }
    }

    // MARK: - Recording

    var isRecording: Bool { recordingSeconds != nil }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        let formats = ringBuffer.formats()
        guard capture.state != .permissionDenied, permissions.screenRecordingGranted, let videoFormat = formats.video else {
            let reason = permissions.screenRecordingGranted
                ? AppLanguage.string("Nothing has been captured yet")
                : AppLanguage.string("No Screen Recording permission")
            fail(title: AppLanguage.string("Couldn't start recording"), message: reason, identifier: "recording")
            return
        }
        // Only the sources that are on, in the order of the tracks.
        let microphoneOn = settings.microphoneEnabled && permissions.microphoneStatus == .granted
        let audioFormats = AudioTrack.allCases.compactMap { track -> (track: AudioTrack, format: CMAudioFormatDescription)? in
            guard track == .system ? settings.systemAudioEnabled : microphoneOn, let format = formats.audio[track] else { return nil }
            return (track, format)
        }
        let game = games.current(within: TimeInterval(settings.bufferSeconds))
        let directory = settings.videosDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let writer = try RecordingWriter(
                url: Self.recordingURL(in: directory),
                videoFormat: videoFormat,
                audioFormats: audioFormats,
                keepStems: settings.keepAudioStems,
                info: ClipInfo(game: game.name, bundleID: game.bundleID, recorded: Date())
            ) { [weak self] _ in
                // The writer cannot go on; what it has is closed as the result.
                Task { @MainActor in await self?.stopRecording() }
            }
            recording.writer = writer
        } catch {
            fail(title: AppLanguage.string("Couldn't start recording"), message: error.localizedDescription, identifier: "recording")
            return
        }
        // The file can only begin with a keyframe.
        encoder.requestKeyframe()
        recordingStart = Date()
        recordingSeconds = 0
        logger.notice("Recording started")
        announce(AppLanguage.string("Recording started"), detail: nil, identifier: "recording")
    }

    /// Returns once the file is closed.
    func stopRecording() async {
        guard let writer = recording.writer, !isEndingRecording else { return }
        isEndingRecording = true
        recording.writer = nil
        let outcome = await writer.finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
        isEndingRecording = false
        recordingStart = nil
        recordingSeconds = nil
        if let url = outcome.url {
            logger.notice("Recording saved: \(url.path, privacy: .public)")
            notifier.saved(url, title: AppLanguage.string("Recording saved"))
            if settings.showHUD {
                hud.show(.success, title: AppLanguage.string("Recording saved"), detail: url.lastPathComponent, in: settings.hudCorner)
            }
        }
        if let error = outcome.error {
            logger.error("Recording ended with an error: \(error.localizedDescription, privacy: .public)")
            fail(
                title: outcome.url == nil ? AppLanguage.string("Recording failed") : AppLanguage.string("Recording ended early"),
                message: error.localizedDescription,
                identifier: "recordingFailed"
            )
        }
    }

    private static func recordingURL(in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "Recording_\(formatter.string(from: Date()))"
        var url = directory.appendingPathComponent("\(name).mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name)_\(suffix).mp4")
            suffix += 1
        }
        return url
    }

    private func announce(_ title: String, detail: String?, identifier: String) {
        notifier.show(title: title, body: detail ?? "", identifier: identifier)
        if settings.showHUD { hud.show(.success, title: title, detail: detail, in: settings.hudCorner) }
    }

    private func fail(title: String, message: String, identifier: String) {
        NSSound.beep()
        report(title: title, body: message, identifier: identifier)
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
            notifier.saved(url, title: AppLanguage.string("Clip saved"))
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

/// The running recording, if any, as seen from the capture threads.
private final class RecordingTap: @unchecked Sendable {
    private let lock = NSLock()
    private var current: RecordingWriter?

    var writer: RecordingWriter? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            lock.unlock()
        }
    }
}
