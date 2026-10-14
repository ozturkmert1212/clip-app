import AVFoundation

/// What a clip or recording knows about itself. Stored inside the mp4 as a
/// JSON comment, so it survives renaming and moving the file.
struct ClipInfo: Codable, Equatable {
    enum AudioRole: String, Codable {
        case mix, system, microphone
    }

    /// The app that was in front when the file was saved. The folder a clip
    /// sits in is its current game; this is the one it was recorded in.
    var game: String
    var bundleID: String?
    var recorded: Date
    /// The audio tracks in file order; `nil` in files written before the
    /// roles were recorded.
    var audio: [AudioRole]?
    /// The levels the mixed track was made with in the editor, by role.
    var levels: [String: Double]?

    private static let identifier = AVMetadataIdentifier.iTunesMetadataUserComment

    var metadataItems: [AVMetadataItem] {
        guard let json else { return [] }
        let item = AVMutableMetadataItem()
        item.identifier = Self.identifier
        item.value = json as NSString
        item.extendedLanguageTag = "und"
        return [item]
    }

    static func read(from asset: AVAsset) async -> ClipInfo? {
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
            if let json = try? await item.load(.stringValue), let info = ClipInfo(json: json) { return info }
        }
        return nil
    }
}

extension ClipInfo {
    /// The record as it is stored in the file.
    var json: String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// `nil` for anything that is not such a record, e.g. another app's comment.
    init?(json: String) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let info = try? decoder.decode(ClipInfo.self, from: Data(json.utf8)) else { return nil }
        self = info
    }
}
