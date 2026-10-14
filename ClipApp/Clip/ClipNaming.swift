import Foundation

/// File names for clips and recordings. There is nothing to configure: a
/// clip is named after its game and the moment it was saved.
enum ClipNaming {
    /// A game name longer than this is cut in the file name (the folder
    /// keeps the whole name).
    static let maximumGameLength = 60

    private static let stampPattern = #"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}"#

    /// `<game>_<yyyy-MM-dd>_<HH-mm-ss>`, without extension. `game` is
    /// expected to be a folder name already, see `GameContext.folderName`.
    static func clipName(game: String, date: Date = Date()) -> String {
        "\(prefix(for: game))_\(stamp(date))"
    }

    /// `Recording_<yyyy-MM-dd>_<HH-mm-ss>`, without extension.
    static func recordingName(date: Date = Date()) -> String {
        "Recording_\(stamp(date))"
    }

    /// The name a clip gets when it moves to another game, or `nil` if its
    /// current name is not the automatic one for `oldGame`: then the user
    /// named it and it stays as it is. The editor's "(trimmed)" or "(edited)"
    /// ending is kept; a `_2` from an earlier name clash is dropped, because
    /// the move resolves clashes afresh.
    static func renamed(_ name: String, from oldGame: String, to newGame: String) -> String? {
        let old = NSRegularExpression.escapedPattern(for: prefix(for: oldGame))
        let pattern = "^\(old)_(\(stampPattern))(?:_\\d+)?( \\((?:trimmed|edited)(?: \\d+)?\\))?$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let stamp = Range(match.range(at: 1), in: name) else { return nil }
        let ending = Range(match.range(at: 2), in: name).map { String(name[$0]) } ?? ""
        return "\(prefix(for: newGame))_\(name[stamp])\(ending)"
    }

    /// `<name>.<ext>` in `directory`, or `<name>_2`, `<name>_3`… if that is taken.
    static func uniqueURL(in directory: URL, name: String, pathExtension: String = "mp4") -> URL {
        var url = directory.appendingPathComponent(name).appendingPathExtension(pathExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name)_\(suffix)").appendingPathExtension(pathExtension)
            suffix += 1
        }
        return url
    }

    private static func prefix(for game: String) -> String {
        guard game.count > maximumGameLength else { return game }
        return String(game.prefix(maximumGameLength)).trimmingCharacters(in: .whitespaces)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}
