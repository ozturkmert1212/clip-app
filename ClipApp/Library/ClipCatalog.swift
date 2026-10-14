import Foundation

struct ClipItem: Identifiable, Equatable {
    enum Category: Hashable {
        /// `Clips/<name>/`.
        case game(String)
        /// Clips from before the folder layout, lying directly in the save folder.
        case other
        /// `Videos/`: recordings rather than instant replays.
        case video
    }

    let url: URL
    let category: Category
    let date: Date
    let size: Int64
    /// Changes whenever the file does; keys the detail and thumbnail caches.
    let fingerprint: String
    /// Read from the file after the list is up, `nil` until then.
    var duration: TimeInterval?
    /// `nil` until read, and for files that carry none.
    var info: ClipInfo?

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// One row of the sidebar's game list.
struct GameGroup: Identifiable, Equatable {
    let name: String
    let count: Int
    /// Of the app the clips were recorded in, for its icon.
    let bundleID: String?

    var id: String { name }
}

/// Where clips and recordings live under the save folder, and what is there.
/// Plain file system work, so it can be used and tested without the app.
enum ClipCatalog {
    /// `Clips/`: one folder per game.
    static func clipsDirectory(in root: URL) -> URL {
        root.appendingPathComponent("Clips", isDirectory: true)
    }

    /// `Videos/`: recordings.
    static func videosDirectory(in root: URL) -> URL {
        root.appendingPathComponent("Videos", isDirectory: true)
    }

    /// `Clips/<game>/`, with the game's name cleaned for use as a folder.
    static func gameDirectory(_ game: String, in root: URL) -> URL {
        clipsDirectory(in: root).appendingPathComponent(GameContext.folderName(game), isDirectory: true)
    }

    /// Every mp4 under `root`, newest first: `Clips/<game>/` as that game's
    /// clips, files directly in `root` or in `Clips/` as `.other` (the layout
    /// before games), `Videos/` as recordings.
    static func list(_ root: URL) -> [ClipItem] {
        var result = files(in: root, category: .other)
        let clips = clipsDirectory(in: root)
        result += files(in: clips, category: .other)
        for folder in subfolders(of: clips) {
            result += files(in: folder, category: .game(folder.lastPathComponent))
        }
        result += files(in: videosDirectory(in: root), category: .video)
        return result.sorted { $0.date > $1.date }
    }

    /// Files the clips under another game by moving them into its folder;
    /// recordings and clips already there are skipped. A clip that still has
    /// its automatic name gets the new game's name in it; one the user
    /// renamed keeps its name. Returns where each moved clip went.
    @discardableResult
    static func move(_ clips: [ClipItem], toGame name: String, root: URL) throws -> [URL] {
        let game = GameContext.folderName(name)
        let directory = gameDirectory(game, in: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var moved: [URL] = []
        for clip in clips where clip.category != .game(game) && clip.category != .video {
            var name = clip.name
            if case .game(let old) = clip.category, let automatic = ClipNaming.renamed(name, from: old, to: game) {
                name = automatic
            }
            let target = ClipNaming.uniqueURL(in: directory, name: name, pathExtension: clip.url.pathExtension)
            try FileManager.default.moveItem(at: clip.url, to: target)
            moved.append(target)
        }
        return moved
    }

    private static func subfolders(of directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )) ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func files(in directory: URL, category: ClipItem.Category) -> [ClipItem] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .compactMap { url -> ClipItem? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                let modified = values.contentModificationDate ?? .distantPast
                let size = Int64(values.fileSize ?? 0)
                return ClipItem(
                    url: url,
                    category: category,
                    date: values.creationDate ?? modified,
                    size: size,
                    fingerprint: "\(url.path)|\(size)|\(modified.timeIntervalSince1970)"
                )
            }
    }
}
