import AppKit
import Combine
import CoreMedia
import OSLog
import ScreenCaptureKit

enum CaptureSource: Hashable, Codable {
    /// `nil` follows the main display.
    case display(CGDirectDisplayID?)
    case window(CGWindowID)
    case application(bundleIdentifier: String)
}

struct SourceOption: Identifiable, Hashable {
    let source: CaptureSource
    let title: String

    var id: CaptureSource { source }
}

struct AvailableSources: Equatable {
    var displays: [SourceOption]
    var applications: [SourceOption] = []
    var windows: [SourceOption] = []

    func contains(_ source: CaptureSource) -> Bool {
        (displays + applications + windows).contains { $0.source == source }
    }
}

struct CaptureConfiguration: Equatable {
    var source: CaptureSource = .display(nil)
    var fps = 60
    /// Output is scaled down to this height; `nil` keeps the native pixel size.
    var maxHeight: Int? = 1080
    /// What is heard follows the source: everything for a display, only the
    /// chosen app for a window or application.
    var capturesSystemAudio = true
}

@MainActor
final class CaptureManager: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        /// `usingFallback`: the chosen source is gone and the main display stands in.
        case running(source: String, width: Int, height: Int, usingFallback: Bool)
        case failed(String)
        case permissionDenied
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var framesLastSecond = 0
    /// What can be captured right now, kept current for the menu bar menu,
    /// which has no moment of its own to ask.
    @Published private(set) var sources = AvailableSources(displays: [])

    var configuration = CaptureConfiguration() {
        didSet {
            if configuration != oldValue, wantsCapture { restart() }
        }
    }

    /// Our own windows that must never end up in a clip (the HUD). Only used
    /// if ClipApp itself cannot be excluded as an application, which covers
    /// every window it has or opens later. Read on every (re)start.
    var excludedWindowIDs: [CGWindowID] = []

    /// Draws every notification banner. Kept out of display captures so that
    /// neither our own "clip saved" banner nor anyone's messages land in a clip.
    /// It also owns the desktop widgets, which disappear from clips with it.
    private static let notificationCenterBundleIdentifier = "com.apple.notificationcenterui"

    private let logger = Logger(subsystem: "com.mertozturk.ClipApp", category: "capture")
    private let captureQueue = DispatchQueue(label: "com.mertozturk.ClipApp.capture", qos: .userInteractive)
    /// Separate so audio never waits behind a frame being handed to the encoder.
    private let audioQueue = DispatchQueue(label: "com.mertozturk.ClipApp.capture.audio", qos: .userInteractive)
    private var stream: SCStream?
    private var output: StreamOutput?
    private var wantsCapture = false
    private var restartTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 1
    private var cancellables: Set<AnyCancellable> = []
    private let onVideoFrame: (CMSampleBuffer) -> Void
    private let onAudioSample: (CMSampleBuffer) -> Void

    /// `onVideoFrame` runs on the capture queue for every complete frame,
    /// `onAudioSample` on the audio queue for every system audio buffer.
    init(onVideoFrame: @escaping (CMSampleBuffer) -> Void, onAudioSample: @escaping (CMSampleBuffer) -> Void) {
        self.onVideoFrame = onVideoFrame
        self.onAudioSample = onAudioSample
        observeSystem()
    }

    func start() {
        guard !wantsCapture else { return }
        wantsCapture = true
        restart()
    }

    func stop() {
        wantsCapture = false
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            await self?.teardown()
        }
        state = .idle
    }

    /// Brings `sources` up to date; cheap enough to call on any hint that
    /// windows or displays may have changed.
    func refreshSources() {
        Task {
            let current = await availableSources()
            if current != sources { sources = current }
        }
    }

    /// What the settings picker offers. Asking ScreenCaptureKit without the
    /// permission would pop the system prompt, so that case returns the default only.
    func availableSources() async -> AvailableSources {
        var result = AvailableSources(displays: [SourceOption(source: .display(nil), title: AppLanguage.string("Main display (automatic)"))])
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        else { return result }

        result.displays += content.displays.map {
            SourceOption(source: .display($0.displayID), title: Self.displayName($0.displayID))
        }

        // Layer 0 with a real size filters out menu bar items, overlays and helpers.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let windows = content.windows.filter { window in
            guard let app = window.owningApplication, !app.bundleIdentifier.isEmpty,
                  app.bundleIdentifier != ownBundleIdentifier else { return false }
            return window.windowLayer == 0 && window.frame.width >= 200 && window.frame.height >= 150
        }
        result.windows = windows.compactMap { window in
            guard let title = window.title, !title.isEmpty, let app = window.owningApplication else { return nil }
            return SourceOption(source: .window(window.windowID), title: "\(app.applicationName) — \(title.prefix(60))")
        }
        var seen: Set<String> = []
        result.applications = windows.compactMap(\.owningApplication)
            .filter { seen.insert($0.bundleIdentifier).inserted }
            .map { SourceOption(source: .application(bundleIdentifier: $0.bundleIdentifier), title: $0.applicationName) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return result
    }

    // MARK: - Stream lifecycle

    /// Every (re)start goes through here so that only one attempt is ever in flight.
    private func restart(after delay: TimeInterval = 0) {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    private func run() async {
        await teardown()
        guard wantsCapture, !Task.isCancelled else { return }
        state = .starting
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !Task.isCancelled else { return }
            let excluded = await exclusions()
            guard !Task.isCancelled else { return }
            let target = try resolve(configuration.source, in: content, excluding: excluded)
            let (width, height) = outputSize(for: target.pixelSize)

            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.width = width
            streamConfiguration.height = height
            streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
            // NV12 is what the hardware H.264 encoder consumes without conversion.
            streamConfiguration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            streamConfiguration.queueDepth = 6
            streamConfiguration.showsCursor = true
            streamConfiguration.scalesToFit = true
            if configuration.capturesSystemAudio {
                streamConfiguration.capturesAudio = true
                streamConfiguration.sampleRate = 48_000
                streamConfiguration.channelCount = 2
                // Keeps the "clip saved" sound out of the clips.
                streamConfiguration.excludesCurrentProcessAudio = true
            }

            let output = StreamOutput(onFrame: onVideoFrame, onAudio: onAudioSample) { [weak self] stream, error in
                Task { @MainActor in self?.streamStopped(stream, error: error) }
            }
            let stream = SCStream(filter: target.filter, configuration: streamConfiguration, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
            if configuration.capturesSystemAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
            }
            try await stream.startCapture()
            guard !Task.isCancelled, wantsCapture else {
                try? await stream.stopCapture()
                return
            }
            self.stream = stream
            self.output = output
            retryDelay = 1
            state = .running(source: target.name, width: width, height: height, usingFallback: target.isFallback)
            logger.info("Capture started: \(target.name, privacy: .public) \(width)x\(height) @ \(self.configuration.fps) fps, system audio \(self.configuration.capturesSystemAudio ? "on" : "off", privacy: .public)\(target.isFallback ? ", fallback for missing source" : "", privacy: .public), \(excluded.windows.count) own window(s) and \(excluded.applications.count) app(s) excluded")
        } catch {
            guard !Task.isCancelled else { return }
            handleFailure(error)
        }
    }

    private func teardown() async {
        guard let stream else { return }
        self.stream = nil
        output = nil
        try? await stream.stopCapture()
    }

    /// Fires when the captured window or app goes away, the display is
    /// disconnected, the machine sleeps, or the user stops sharing from the menu bar.
    private func streamStopped(_ stopped: SCStream, error: Error) {
        guard stopped === stream else { return }
        stream = nil
        output = nil
        handleFailure(error)
    }

    private func handleFailure(_ error: Error) {
        let nsError = error as NSError
        logger.error("Capture failed: \(nsError.domain, privacy: .public) \(nsError.code) \(nsError.localizedDescription, privacy: .public)")
        if nsError.domain == SCStreamErrorDomain, nsError.code == SCStreamError.Code.userDeclined.rawValue {
            wantsCapture = false
            state = .permissionDenied
            return
        }
        state = .failed(nsError.localizedDescription)
        guard wantsCapture else { return }
        restart(after: retryDelay)
        retryDelay = min(retryDelay * 2, 10)
    }

    private func observeSystem() {
        // Windows come and go without any notification of their own; app
        // activations catch most of it and the timer the rest.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification))
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSources() }
            .store(in: &cancellables)
        Timer.publish(every: 10, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshSources() }
            .store(in: &cancellables)
        refreshSources()

        // Resolution changes and display (dis)connects invalidate the stream geometry.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.restartIfCapturing(after: 0.5) }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restartIfCapturing(after: 1) }
            .store(in: &cancellables)

        // An application source falls back to the display while the app is closed
        // and has to be re-resolved when it comes back.
        workspace.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                else { return }
                // A relaunched Notification Center is a new process the filter does not know.
                var relevant = app.bundleIdentifier == Self.notificationCenterBundleIdentifier
                if case .application(let bundleIdentifier) = self.configuration.source {
                    relevant = relevant || app.bundleIdentifier == bundleIdentifier
                }
                if relevant { self.restartIfCapturing(after: 0.5) }
            }
            .store(in: &cancellables)

        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let frames = self.output?.takeFrameCount() ?? 0
                if frames != self.framesLastSecond { self.framesLastSecond = frames }
            }
            .store(in: &cancellables)
    }

    private func restartIfCapturing(after delay: TimeInterval) {
        guard wantsCapture else { return }
        restart(after: delay)
    }

    // MARK: - Source resolution

    private struct Target {
        let filter: SCContentFilter
        let name: String
        let pixelSize: CGSize
        var isFallback = false
    }

    private enum CaptureError: LocalizedError {
        case noDisplay

        var errorDescription: String? { AppLanguage.string("No display found to capture") }
    }

    /// A window or app that no longer exists falls back to the main display, so
    /// the buffer keeps filling after a game quits.
    private func resolve(_ source: CaptureSource, in content: SCShareableContent, excluding excluded: Exclusions) throws -> Target {
        let mainDisplay = content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first

        switch source {
        case .window(let windowID):
            if let window = content.windows.first(where: { $0.windowID == windowID }) {
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let scale: CGFloat
                if #available(macOS 14.0, *) {
                    scale = CGFloat(filter.pointPixelScale)
                } else {
                    scale = NSScreen.main?.backingScaleFactor ?? 2
                }
                let name = window.title.flatMap { $0.isEmpty ? nil : $0 }
                    ?? window.owningApplication?.applicationName ?? AppLanguage.string("Window")
                let size = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
                return Target(filter: filter, name: name, pixelSize: size)
            }
        case .application(let bundleIdentifier):
            if let app = content.applications.first(where: { $0.bundleIdentifier == bundleIdentifier }),
               let display = mainDisplay {
                let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                return Target(filter: filter, name: app.applicationName, pixelSize: pixelSize(of: display))
            }
        case .display(let displayID):
            if let displayID, let display = content.displays.first(where: { $0.displayID == displayID }) {
                return displayTarget(display, excluding: excluded)
            }
            if displayID == nil, let mainDisplay {
                return displayTarget(mainDisplay, excluding: excluded)
            }
        }

        guard let mainDisplay else { throw CaptureError.noDisplay }
        var target = displayTarget(mainDisplay, excluding: excluded)
        target.isFallback = true
        return target
    }

    /// What a display capture leaves out. Window and app sources show a single
    /// app, so there is nothing to remove from them.
    private struct Exclusions {
        var windows: [SCWindow] = []
        var applications: [SCRunningApplication] = []
    }

    /// Looked up separately: the HUD and the banners are off screen most of the
    /// time and `run()` only lists on-screen windows.
    private func exclusions() async -> Exclusions {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else {
            logger.error("Nothing excluded from capture: shareable content unavailable")
            return Exclusions()
        }
        // Excluding ClipApp as an application keeps the main window, its
        // sheets and menus and the HUD out of clips without tracking window IDs.
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let notificationCenter = content.applications.filter {
            $0.bundleIdentifier == Self.notificationCenterBundleIdentifier
        }
        let result = Exclusions(
            windows: own.isEmpty ? content.windows.filter { excludedWindowIDs.contains($0.windowID) } : [],
            applications: own + notificationCenter
        )
        if own.isEmpty {
            logger.error("ClipApp not found as an application; excluding \(result.windows.count) of \(self.excludedWindowIDs.count) own window(s) instead")
        }
        if notificationCenter.isEmpty {
            logger.error("Notification Center not found; banners will be captured")
        }
        return result
    }

    private func displayTarget(_ display: SCDisplay, excluding excluded: Exclusions) -> Target {
        Target(
            // With excluded apps, a window of any other app listed as an
            // exception is left out as well.
            filter: SCContentFilter(
                display: display,
                excludingApplications: excluded.applications,
                exceptingWindows: excluded.windows
            ),
            name: Self.displayName(display.displayID),
            pixelSize: pixelSize(of: display)
        )
    }

    private static func displayName(_ displayID: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
        return screen?.localizedName ?? AppLanguage.string("Display")
    }

    private func pixelSize(of display: SCDisplay) -> CGSize {
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        return CGSize(width: display.width, height: display.height)
    }

    /// H.264 needs even dimensions.
    private func outputSize(for pixelSize: CGSize) -> (width: Int, height: Int) {
        var width = pixelSize.width
        var height = pixelSize.height
        if let maxHeight = configuration.maxHeight, height > CGFloat(maxHeight) {
            width = width * CGFloat(maxHeight) / height
            height = CGFloat(maxHeight)
        }
        return (max(2, Int(width.rounded()) & ~1), max(2, Int(height.rounded()) & ~1))
    }
}

/// Receives frames on the capture queue. Kept separate from `CaptureManager`
/// because ScreenCaptureKit calls it off the main actor.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onFrame: (CMSampleBuffer) -> Void
    private let onAudio: (CMSampleBuffer) -> Void
    private let onStop: (SCStream, Error) -> Void
    private let frameCount = OSAllocatedUnfairLock(initialState: 0)

    init(
        onFrame: @escaping (CMSampleBuffer) -> Void,
        onAudio: @escaping (CMSampleBuffer) -> Void,
        onStop: @escaping (SCStream, Error) -> Void
    ) {
        self.onFrame = onFrame
        self.onAudio = onAudio
        self.onStop = onStop
    }

    func takeFrameCount() -> Int {
        frameCount.withLock { count in
            defer { count = 0 }
            return count
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type == .audio {
            onAudio(sampleBuffer)
        } else if type == .screen, Self.isComplete(sampleBuffer) {
            frameCount.withLock { $0 += 1 }
            onFrame(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(stream, error)
    }

    /// ScreenCaptureKit also delivers idle/blank status frames that carry no image.
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: rawStatus) == .complete
    }
}
