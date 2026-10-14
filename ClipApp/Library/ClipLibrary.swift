import AppKit
import AVFoundation
import Combine
import OSLog

/// The mp4 files under the save folder, newest first: clips by game, clips
/// from the old flat layout and recordings. Follows the folder, so a saved,
/// renamed, moved or deleted file shows up without a manual refresh.
@MainActor
final class ClipLibrary: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    /// False until the folder has been read once, so an empty folder and a
    /// list that is still loading can be told apart.
    @Published private(set) var isLoaded = false

    private let logger = Logger(subsystem: "com.mertozturk.ClipApp", category: "library")
    private let settings: SettingsStore
    private var watcher: FolderWatcher?
    private var details: [String: (duration: TimeInterval?, info: ClipInfo?)] = [:]
    private var reloadTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore) {
        self.settings = settings
        settings.$saveDirectory
            .removeDuplicates()
            .sink { [weak self] in self?.watch($0) }
            .store(in: &cancellables)
    }

    var clips: [ClipItem] { items.filter { $0.category != .video } }
    var videos: [ClipItem] { items.filter { $0.category == .video } }
    var otherCount: Int { items.filter { $0.category == .other }.count }

    /// Games by name, each with the app its newest tagged clip came from.
    var games: [GameGroup] {
        var counts: [String: Int] = [:]
        var bundleIDs: [String: String] = [:]
        for item in items {
            guard case .game(let name) = item.category else { continue }
            counts[name, default: 0] += 1
            if bundleIDs[name] == nil, let bundleID = item.info?.bundleID { bundleIDs[name] = bundleID }
        }
        return counts.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { GameGroup(name: $0, count: counts[$0] ?? 0, bundleID: bundleIDs[$0]) }
    }

    // MARK: - Actions

    func refresh() {
        scheduleReload()
    }

    func reveal(_ clips: [ClipItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(clips.map(\.url))
    }

    func copy(_ clips: [ClipItem]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(clips.map { $0.url as NSURL })
    }

    /// Stops at the first file that cannot be moved; the ones before it are gone.
    func trash(_ clips: [ClipItem]) throws {
        defer { scheduleReload() }
        for clip in clips {
            try FileManager.default.trashItem(at: clip.url, resultingItemURL: nil)
        }
    }

    /// `name` is the new file name without extension.
    func rename(_ clip: ClipItem, to name: String) throws {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != clip.name else { return }
        let target = clip.url.deletingLastPathComponent()
            .appendingPathComponent(cleaned)
            .appendingPathExtension(clip.url.pathExtension)
        try FileManager.default.moveItem(at: clip.url, to: target)
        scheduleReload()
    }

    /// Files the clips under another game by moving them into its folder.
    /// A clip that still has its automatic name gets the new game's name in
    /// it; one the user renamed keeps its name. The game recorded inside
    /// each file stays what it was.
    func move(_ clips: [ClipItem], toGame name: String) throws {
        defer { scheduleReload() }
        try ClipCatalog.move(clips, toGame: name, root: settings.saveDirectory)
    }

    // MARK: - Folder

    private func watch(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        watcher = FolderWatcher(directory) { [weak self] in self?.scheduleReload() }
        if watcher == nil { logger.error("Can't watch the save folder: \(directory.path, privacy: .public)") }
        scheduleReload()
    }

    /// Several events arrive for one change, so reloads are coalesced.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    private func reload() async {
        let root = settings.saveDirectory
        var found = await Task.detached(priority: .userInitiated) { ClipCatalog.list(root) }.value
        guard !Task.isCancelled else { return }
        for index in found.indices {
            if let known = details[found[index].fingerprint] {
                found[index].duration = known.duration
                found[index].info = known.info
            }
        }
        items = found
        isLoaded = true

        for clip in found where details[clip.fingerprint] == nil {
            let asset = AVURLAsset(url: clip.url)
            // An unreadable file, e.g. one still being written, is asked again
            // on the next reload, which its completion triggers.
            guard let time = try? await asset.load(.duration), time.isNumeric else { continue }
            let info = await ClipInfo.read(from: asset)
            guard !Task.isCancelled else { return }
            details[clip.fingerprint] = (time.seconds, info)
            if let index = items.firstIndex(where: { $0.fingerprint == clip.fingerprint }) {
                items[index].duration = time.seconds
                items[index].info = info
            }
        }
    }
}

/// Reports changes anywhere under a folder, including a file that is still
/// growing, which a directory descriptor would not see.
private final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(_ directory: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
            },
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
