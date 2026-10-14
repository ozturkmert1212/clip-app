import Foundation
import ServiceManagement

/// User settings, persisted in `UserDefaults`. Everything that reacts to a
/// change observes `objectWillChange`.
@MainActor
final class SettingsStore: ObservableObject {
    enum Resolution: String, CaseIterable, Identifiable {
        case p720, p1080, p1440, native

        var id: String { rawValue }

        var maxHeight: Int? {
            switch self {
            case .p720: return 720
            case .p1080: return 1080
            case .p1440: return 1440
            case .native: return nil
            }
        }

        var title: String {
            switch self {
            case .p720: return "720p"
            case .p1080: return "1080p"
            case .p1440: return "1440p"
            case .native: return String(localized: "Native")
            }
        }
    }

    static let bufferOptions = [15, 30, 60, 120]
    static let fpsOptions = [30, 60]
    static let bitrateOptions = [4, 6, 8, 12, 16, 24, 40]
    static let audioLevelRange = 0.0...2.0
    static let defaultFileNameFormat = "Clip_{date}_{time}"

    @Published var bufferSeconds: Int { didSet { defaults.set(bufferSeconds, forKey: Key.bufferSeconds) } }
    @Published var resolution: Resolution { didSet { defaults.set(resolution.rawValue, forKey: Key.resolution) } }
    @Published var fps: Int { didSet { defaults.set(fps, forKey: Key.fps) } }
    @Published var bitrateMbps: Int { didSet { defaults.set(bitrateMbps, forKey: Key.bitrateMbps) } }
    @Published var source: CaptureSource {
        didSet { defaults.set(try? JSONEncoder().encode(source), forKey: Key.source) }
    }
    @Published var systemAudioEnabled: Bool { didSet { defaults.set(systemAudioEnabled, forKey: Key.systemAudioEnabled) } }
    @Published var microphoneEnabled: Bool { didSet { defaults.set(microphoneEnabled, forKey: Key.microphoneEnabled) } }
    /// Linear gain, 1 = unchanged.
    @Published var systemAudioLevel: Double { didSet { defaults.set(systemAudioLevel, forKey: Key.systemAudioLevel) } }
    @Published var microphoneLevel: Double { didSet { defaults.set(microphoneLevel, forKey: Key.microphoneLevel) } }
    /// One mixed audio track instead of one per source. Most players other
    /// than QuickTime only play the first audio track.
    @Published var mixAudioTracks: Bool { didSet { defaults.set(mixAudioTracks, forKey: Key.mixAudioTracks) } }
    @Published var saveDirectory: URL { didSet { defaults.set(saveDirectory.path, forKey: Key.saveDirectory) } }
    @Published var fileNameFormat: String { didSet { defaults.set(fileNameFormat, forKey: Key.fileNameFormat) } }

    /// On-screen confirmation for saved clips and problems, see `HUD`.
    @Published var showHUD: Bool { didSet { defaults.set(showHUD, forKey: Key.showHUD) } }
    @Published var hudCorner: HUD.Corner { didSet { defaults.set(hudCorner.rawValue, forKey: Key.hudCorner) } }

    /// Whether the main window comes up at launch. A launch as a login item
    /// never opens it.
    @Published var openWindowAtLaunch: Bool { didSet { defaults.set(openWindowAtLaunch, forKey: Key.openWindowAtLaunch) } }

    /// Takes effect at the next launch, see `AppLanguage`.
    @Published var language: AppLanguage { didSet { AppLanguage.selected = language } }

    /// The system owns this state; it is never stored in `UserDefaults`.
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var launchAtLoginError: String?

    /// The login item is registered for wherever the app runs from, so a copy
    /// in a build folder would break as soon as that folder is cleaned.
    let runsFromApplications = Bundle.main.bundlePath.hasPrefix("/Applications/")
        || Bundle.main.bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")

    private let defaults = UserDefaults.standard

    private enum Key {
        static let bufferSeconds = "bufferSeconds"
        static let resolution = "resolution"
        static let fps = "fps"
        static let bitrateMbps = "bitrateMbps"
        static let source = "captureSource"
        static let systemAudioEnabled = "systemAudioEnabled"
        static let microphoneEnabled = "microphoneEnabled"
        static let systemAudioLevel = "systemAudioLevel"
        static let microphoneLevel = "microphoneLevel"
        static let mixAudioTracks = "mixAudioTracks"
        static let saveDirectory = "saveDirectory"
        static let fileNameFormat = "fileNameFormat"
        static let showHUD = "showHUD"
        static let hudCorner = "hudCorner"
        static let openWindowAtLaunch = "openWindowAtLaunch"
    }

    init() {
        let defaults = UserDefaults.standard
        // Stored values are checked against the offered options so a stale or
        // hand-edited value cannot put the pipeline in an unsupported state.
        let buffer = defaults.integer(forKey: Key.bufferSeconds)
        bufferSeconds = Self.bufferOptions.contains(buffer) ? buffer : 30
        resolution = defaults.string(forKey: Key.resolution).flatMap(Resolution.init) ?? .p1080
        let fps = defaults.integer(forKey: Key.fps)
        self.fps = Self.fpsOptions.contains(fps) ? fps : 60
        let bitrate = defaults.integer(forKey: Key.bitrateMbps)
        bitrateMbps = Self.bitrateOptions.contains(bitrate) ? bitrate : 12
        source = defaults.data(forKey: Key.source)
            .flatMap { try? JSONDecoder().decode(CaptureSource.self, from: $0) } ?? .display(nil)
        systemAudioEnabled = defaults.object(forKey: Key.systemAudioEnabled) as? Bool ?? true
        microphoneEnabled = defaults.bool(forKey: Key.microphoneEnabled)
        let level = { (key: String) -> Double in
            guard let stored = defaults.object(forKey: key) as? Double else { return 1 }
            return min(max(stored, Self.audioLevelRange.lowerBound), Self.audioLevelRange.upperBound)
        }
        systemAudioLevel = level(Key.systemAudioLevel)
        microphoneLevel = level(Key.microphoneLevel)
        mixAudioTracks = defaults.object(forKey: Key.mixAudioTracks) as? Bool ?? true
        saveDirectory = defaults.string(forKey: Key.saveDirectory).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ClipApp", isDirectory: true)
        fileNameFormat = defaults.string(forKey: Key.fileNameFormat) ?? Self.defaultFileNameFormat
        showHUD = defaults.object(forKey: Key.showHUD) as? Bool ?? true
        hudCorner = defaults.string(forKey: Key.hudCorner).flatMap(HUD.Corner.init) ?? .topLeft
        openWindowAtLaunch = defaults.object(forKey: Key.openWindowAtLaunch) as? Bool ?? true
        language = AppLanguage.selected
    }

    var captureConfiguration: CaptureConfiguration {
        CaptureConfiguration(
            source: source,
            fps: fps,
            maxHeight: resolution.maxHeight,
            capturesSystemAudio: systemAudioEnabled
        )
    }

    var bitrate: Int { bitrateMbps * 1_000_000 }

    /// Three times what the buffer would hold at exactly the target bitrate.
    var bufferByteLimit: Int { bufferSeconds * bitrate / 8 * 3 }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = SMAppService.mainApp.status == .requiresApproval
                ? String(localized: "You need to allow ClipApp under System Settings > General > Login Items.")
                : nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// File name without extension. Supports `{date}`, `{time}` and `{source}`.
    func clipFileName(date: Date = Date(), source: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH-mm-ss"
        let time = formatter.string(from: date)

        let format = fileNameFormat.trimmingCharacters(in: .whitespaces).isEmpty
            ? Self.defaultFileNameFormat : fileNameFormat
        let name = format
            .replacingOccurrences(of: "{date}", with: day)
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{source}", with: source)
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Clip" : name
    }
}
