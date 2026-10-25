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
    /// Set while a recording waits for the stream to deliver its first frames.
    @Published private(set) var isStartingRecording = false
    /// Whether clipping is on and a recording runs, which decides whether the
    /// stream runs and the buffer fills. Changed only through `setActivity`.
    @Published private(set) var activity = CaptureActivity()

    let capture: CaptureManager

    /// Shows the Settings tab, where the permissions are; a click on a
    /// permission notification ends up here.
    var onOpenSettings: () -> Void = {} {
        didSet { notifier.onOpenSettings = onOpenSettings }
    }

    private let settings: SettingsStore
    private let permissions: PermissionManager
    private let ringBuffer: RingBuffer
    private let encoder: EncoderPipeline
    private let systemAudio: AudioPipeline
    private let microphoneAudio: AudioPipeline
    private let microphone: MicrophoneCapture
    private var hotkeys: HotkeyManager?
    /// Where the pipeline's output goes: the buffer while clipping, the
    /// recording while one runs.
    private let tap: PipelineTap
    private var recordingStart: Date?
    private var isEndingRecording = false
    private var askedForMicrophone = false
    private var appliedSource: CaptureSource?
    private var appliedLanguage: AppLanguage?
    private let notifier: Notifier
    private let games = GameTracker()
    private let hud = HUD()
    private let windowSharing: WindowSharing
    private let logger = Logger(subsystem: "com.mertozturk.ClipApp", category: "clip")
    private var outageTask: Task<Void, Never>?
    private var reportedFallback = false
    private var lastFailure = ""
    private var cancellables: Set<AnyCancellable> = []

    /// The notifier is shared with the updater: there is one notification
    /// center delegate per app.
    init(settings: SettingsStore, permissions: PermissionManager, notifier: Notifier) {
        self.notifier = notifier
        let ringBuffer = RingBuffer(
            duration: TimeInterval(settings.bufferSeconds),
            byteLimit: settings.bufferByteLimit
        )
        // The replay buffer keeps filling during a recording if clipping is
        // on; the recording gets the same samples on the side.
        let tap = PipelineTap(ringBuffer: ringBuffer)
        let encoder = EncoderPipeline(fps: settings.fps, bitrate: settings.bitrate) { tap.video($0) }
        let systemAudio = AudioPipeline { tap.audio($0, from: .system) }
        let microphoneAudio = AudioPipeline { tap.audio($0, from: .microphone) }
        self.tap = tap
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
        windowSharing = WindowSharing(neverShared: [hud.windowID])
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
        // Granted while the stream is wanted (it normally takes a relaunch).
        permissions.$screenRecordingGranted
            .removeDuplicates()
            .sink { [weak self] granted in
                guard let self, granted, self.activity.streamRuns else { return }
                self.capture.start()
            }
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
                body: AppLanguage.string("Capture stopped, clips can't be saved. Click to open ClipApp's Settings, where the permission is granted."),
                hudDetail: AppLanguage.string("Capture stopped, clips can't be saved"),
                identifier: "capture",
                opensSettings: true
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
        case .idle:
            // Stopped on purpose: whatever was failing no longer matters.
            outageTask?.cancel()
            outageTask = nil
        case .starting:
            break
        }
    }

    /// A problem goes out both ways: the notification stays in Notification
    /// Center, the HUD is what is actually seen while the screen is captured.
    private func report(title: String, body: String, hudDetail: String? = nil, identifier: String, opensSettings: Bool = false) {
        notifier.show(title: title, body: body, identifier: identifier, opensSettings: opensSettings)
        if settings.showHUD { hud.show(.failure, title: title, detail: hudDetail ?? body, in: settings.hudCorner) }
    }

    /// Pushes every setting down; each component ignores values it already has.
    private func applySettings() {
        ringBuffer.setDuration(TimeInterval(settings.bufferSeconds))
        ringBuffer.setByteLimit(settings.bufferByteLimit)
        encoder.configure(fps: settings.fps, bitrate: settings.bitrate)
        // A clip never mixes two sources: what the old one left goes.
        if let appliedSource, appliedSource != settings.source { ringBuffer.reset() }
        appliedSource = settings.source
        capture.configuration = settings.captureConfiguration
        // Applied to the running stream in place, the buffer stays.
        capture.showsClipApp = settings.showClipAppInCaptures
        windowSharing.setShareable(settings.showClipAppInCaptures)
        // The source list holds finished titles.
        if appliedLanguage != settings.language {
            appliedLanguage = settings.language
            capture.refreshSources()
        }

        systemAudio.setGain(Float(settings.systemAudioLevel))
        microphoneAudio.setGain(Float(settings.microphoneLevel))
        // Switched on from Settings or the menu before it was ever asked for.
        if settings.microphoneEnabled, permissions.microphoneStatus == .notDetermined, !askedForMicrophone {
            askedForMicrophone = true
            permissions.requestMicrophone()
        }
        // Only while the stream runs, so a stopped app shows no microphone indicator either.
        let microphoneOn = activity.streamRuns && microphoneWanted
        microphone.setEnabled(microphoneOn)
        // A source that was just switched off must not show up in the next clip.
        if !settings.systemAudioEnabled { ringBuffer.removeAudio(.system) }
        if !microphoneOn { ringBuffer.removeAudio(.microphone) }
    }

    private var microphoneWanted: Bool {
        settings.microphoneEnabled && permissions.microphoneStatus == .granted
    }

    // MARK: - Clipping

    var isClipping: Bool { activity.isClipping }

    /// Starts the stream (unless a recording already runs it) and the buffer.
    /// Without the permission it asks for it, the first time, and shows
    /// Settings, where it is granted.
    func startClipping() {
        guard !activity.isClipping else { return }
        guard permissions.screenRecordingGranted else {
            logger.notice("Start clipping: no Screen Recording permission")
            if !permissions.screenRecordingRequested { permissions.requestScreenRecording() }
            onOpenSettings()
            return
        }
        var next = activity
        next.isClipping = true
        setActivity(next)
    }

    /// Empties the buffer; the stream stops unless a recording runs.
    func stopClipping() {
        guard activity.isClipping else { return }
        var next = activity
        next.isClipping = false
        setActivity(next)
    }

    private func setRecordingActivity(_ isRecording: Bool) {
        var next = activity
        next.isRecording = isRecording
        setActivity(next)
    }

    private func setActivity(_ next: CaptureActivity) {
        let effects = activity.effects(to: next)
        activity = next
        for effect in effects {
            switch effect {
            case .clearBuffer: tap.setBuffering(false)
            case .fillBuffer: tap.setBuffering(true)
            case .startStream:
                // Formats from an earlier stream say nothing about the next one.
                tap.forgetFormats()
                capture.start()
            case .stopStream: capture.stop()
            }
        }
        logger.notice("Clipping \(next.isClipping ? "on" : "off", privacy: .public), recording \(next.isRecording ? "on" : "off", privacy: .public), stream \(next.streamRuns ? "runs" : "stopped", privacy: .public)")
        if !next.fillsBuffer {
            bufferedSeconds = 0
            byteLimitedSeconds = nil
        }
        // The microphone follows the stream.
        applySettings()
    }

    func saveClip() {
        guard !isSaving else { return }
        // Nothing is kept while clipping is off; the shortcut only says so.
        guard activity.canSaveClip else {
            logger.notice("Save clip: clipping is off")
            let title = AppLanguage.string("Clipping is off")
            let detail = AppLanguage.string("Press Start Clipping first")
            if settings.showHUD {
                hud.show(.failure, title: title, detail: detail, in: settings.hudCorner)
            } else {
                notifier.show(title: title, body: detail, identifier: "clipFailed")
            }
            return
        }
        // Without the permission the buffer is empty or holds stale footage.
        if capture.state == .permissionDenied || !permissions.screenRecordingGranted {
            isSaving = false
            lastResult = .failed(AppLanguage.string("No Screen Recording permission"))
            NSSound.beep()
            report(
                title: AppLanguage.string("Couldn't save clip"),
                body: AppLanguage.string("No Screen Recording permission. Click to open ClipApp's Settings."),
                hudDetail: AppLanguage.string("No Screen Recording permission"),
                identifier: "clipFailed",
                opensSettings: true
            )
            return
        }
        // Capture timestamps are on the host clock, so "now" is too.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        guard let snapshot = ringBuffer.snapshot(endingAt: now) else {
            finish(.failed(ClipWriter.WriteError.emptyBuffer.localizedDescription))
            return
        }
        // Filed under the app in front right now (not when the write finishes),
        // or the one that was in front during the clip if ClipApp is now.
        let game = games.current(within: TimeInterval(settings.bufferSeconds))
        let directory = ClipCatalog.gameDirectory(game.name, in: settings.saveDirectory)
        let info = ClipInfo(game: game.name, bundleID: game.bundleID, recorded: Date())
        let name = ClipNaming.clipName(game: game.name)
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
        guard !isStartingRecording else { return }
        if isRecording {
            Task { await stopRecording() }
        } else {
            startRecording()
        }
    }

    /// With clipping off this starts the stream first and waits for what it
    /// delivers, since the file is set up for the formats coming out of the
    /// pipeline.
    func startRecording() {
        guard !isRecording, !isStartingRecording else { return }
        guard permissions.screenRecordingGranted else {
            fail(title: AppLanguage.string("Couldn't start recording"), message: AppLanguage.string("No Screen Recording permission"), identifier: "recording")
            return
        }
        isStartingRecording = true
        setRecordingActivity(true)
        Task {
            let formats = await currentFormats()
            isStartingRecording = false
            guard activity.isRecording else { return }
            beginRecording(with: formats)
        }
    }

    /// The pipeline's formats once video is coming out, with a moment more
    /// for the audio sources that are on: a stream that was just started
    /// delivers its first audio a little after its first frame.
    private func currentFormats() async -> PipelineTap.Formats {
        let expected = Set(AudioTrack.allCases.filter { $0 == .system ? settings.systemAudioEnabled : microphoneWanted })
        let start = Date()
        var videoSince: Date?
        while true {
            let formats = tap.formats()
            if formats.video != nil {
                let since = videoSince ?? Date()
                videoSince = since
                if expected.isSubset(of: formats.audio.keys) || Date().timeIntervalSince(since) > 1 { return formats }
            } else if Date().timeIntervalSince(start) > 5 || !activity.isRecording || capture.state == .permissionDenied {
                return formats
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func beginRecording(with formats: PipelineTap.Formats) {
        guard let videoFormat = formats.video else {
            setRecordingActivity(false)
            let reason = permissions.screenRecordingGranted && capture.state != .permissionDenied
                ? AppLanguage.string("Nothing has been captured yet")
                : AppLanguage.string("No Screen Recording permission")
            fail(title: AppLanguage.string("Couldn't start recording"), message: reason, identifier: "recording")
            return
        }
        // Only the sources that are on, in the order of the tracks.
        let microphoneOn = microphoneWanted
        let audioFormats = AudioTrack.allCases.compactMap { track -> (track: AudioTrack, format: CMAudioFormatDescription)? in
            guard track == .system ? settings.systemAudioEnabled : microphoneOn, let format = formats.audio[track] else { return nil }
            return (track, format)
        }
        let game = games.current(within: TimeInterval(settings.bufferSeconds))
        let directory = settings.videosDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let writer = try RecordingWriter(
                url: ClipNaming.uniqueURL(in: directory, name: ClipNaming.recordingName()),
                videoFormat: videoFormat,
                audioFormats: audioFormats,
                keepStems: settings.keepAudioStems,
                info: ClipInfo(game: game.name, bundleID: game.bundleID, recorded: Date())
            ) { [weak self] _ in
                // The writer cannot go on; what it has is closed as the result.
                Task { @MainActor in await self?.stopRecording() }
            }
            tap.writer = writer
        } catch {
            setRecordingActivity(false)
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
        guard let writer = tap.writer, !isEndingRecording else { return }
        isEndingRecording = true
        tap.writer = nil
        let outcome = await writer.finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
        isEndingRecording = false
        recordingStart = nil
        recordingSeconds = nil
        // With clipping off the stream was only running for the recording.
        setRecordingActivity(false)
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

    private func announce(_ title: String, detail: String?, identifier: String) {
        notifier.show(title: title, body: detail ?? "", identifier: identifier)
        if settings.showHUD { hud.show(.success, title: title, detail: detail, in: settings.hudCorner) }
    }

    private func fail(title: String, message: String, identifier: String) {
        NSSound.beep()
        report(title: title, body: message, identifier: identifier)
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

/// Where the pipeline's samples go, as seen from the capture threads: the
/// replay buffer while clipping is on, the recording while one runs. It also
/// keeps the newest format of each, which is what a recording is set up for.
private final class PipelineTap: @unchecked Sendable {
    struct Formats {
        var video: CMFormatDescription?
        var audio: [AudioTrack: CMAudioFormatDescription] = [:]
    }

    private let lock = NSLock()
    private let ringBuffer: RingBuffer
    private var buffering = false
    private var current: RecordingWriter?
    private var latest = Formats()

    init(ringBuffer: RingBuffer) {
        self.ringBuffer = ringBuffer
    }

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

    /// Off empties the buffer. Under the same lock as the appends, so no
    /// sample that was on its way slips in after the reset.
    func setBuffering(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        buffering = on
        if !on { ringBuffer.reset() }
    }

    func formats() -> Formats {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func forgetFormats() {
        lock.lock()
        latest = Formats()
        lock.unlock()
    }

    func video(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        latest.video = sample.formatDescription
        if buffering { ringBuffer.append(sample) }
        current?.appendVideo(sample)
    }

    func audio(_ sample: CMSampleBuffer, from track: AudioTrack) {
        lock.lock()
        defer { lock.unlock() }
        latest.audio[track] = sample.formatDescription
        if buffering { ringBuffer.append(sample, to: track) }
        current?.appendAudio(sample, from: track)
    }
}
