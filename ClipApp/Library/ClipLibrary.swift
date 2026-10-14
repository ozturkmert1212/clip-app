import AppKit
import AVFoundation
import Combine
import OSLog

struct ClipItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let size: Int64
    /// Changes whenever the file does; keys the duration and thumbnail caches.
    let fingerprint: String
    /// Read from the file after the list is up, `nil` until then.
    var duration: TimeInterval?

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// The mp4 files in the save folder, newest first. Follows the folder: a
/// saved, renamed or deleted clip shows up without a manual refresh.
@MainActor
final class ClipLibrary: ObservableObject {
    @Published private(set) var clips: [ClipItem] = []
    /// False until the folder has been read once, so an empty folder and a
    /// list that is still loading can be told apart.
    @Published private(set) var isLoaded = false

    private let logger = Logger(subsystem: "com.mertozturk.ClipApp", category: "library")
    private var directory: URL
    private var watcher: DispatchSourceFileSystemObject?
    private var durations: [String: TimeInterval] = [:]
    private var reloadTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore, controller: ClipController) {
        directory = settings.saveDirectory
        settings.$saveDirectory
            .removeDuplicates()
            .sink { [weak self] in self?.watch($0) }
            .store(in: &cancellables)
        // The folder only reports that a file appeared, not that the writer
        // finished it; this is what picks up the final size and duration.
        controller.$lastResult
            .dropFirst()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    /// For a file written by the app itself: the folder reports that it
    /// appeared, but not that it is complete.
    func refresh() {
        scheduleReload()
    }

    func reveal(_ clip: ClipItem) {
        NSWorkspace.shared.activateFileViewerSelecting([clip.url])
    }

    func copy(_ clip: ClipItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([clip.url as NSURL])
    }

    func trash(_ clip: ClipItem) throws {
        try FileManager.default.trashItem(at: clip.url, resultingItemURL: nil)
        scheduleReload()
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

    // MARK: - Folder

    private func watch(_ directory: URL) {
        self.directory = directory
        watcher?.cancel()
        watcher = nil
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                // The folder itself was moved or deleted: follow the path again.
                if !source.data.isDisjoint(with: [.delete, .rename]) {
                    self.watch(self.directory)
                } else {
                    self.scheduleReload()
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        } else {
            logger.error("Can't watch the clips folder: \(directory.path, privacy: .public)")
        }
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
        let directory = directory
        var found = await Task.detached(priority: .userInitiated) { Self.list(directory) }.value
        guard !Task.isCancelled else { return }
        for index in found.indices {
            found[index].duration = durations[found[index].fingerprint]
        }
        clips = found
        isLoaded = true

        for clip in found where clip.duration == nil {
            // An unreadable file, e.g. one still being written, stays without one.
            guard let time = try? await AVURLAsset(url: clip.url).load(.duration), time.isNumeric else { continue }
            guard !Task.isCancelled else { return }
            durations[clip.fingerprint] = time.seconds
            if let index = clips.firstIndex(where: { $0.fingerprint == clip.fingerprint }) {
                clips[index].duration = time.seconds
            }
        }
    }

    nonisolated private static func list(_ directory: URL) -> [ClipItem] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .compactMap { url -> ClipItem? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                let modified = values.contentModificationDate ?? .distantPast
                let size = Int64(values.fileSize ?? 0)
                return ClipItem(
                    url: url,
                    date: values.creationDate ?? modified,
                    size: size,
                    fingerprint: "\(url.path)|\(size)|\(modified.timeIntervalSince1970)"
                )
            }
            .sorted { $0.date > $1.date }
    }
}
