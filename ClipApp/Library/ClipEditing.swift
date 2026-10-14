import CoreMedia
import Foundation

/// The part of a clip the editor's two handles enclose.
struct TrimSelection: Equatable {
    /// The shortest selection the handles allow.
    static let minimumLength: TimeInterval = 0.5

    private(set) var duration: TimeInterval
    private(set) var start: TimeInterval = 0
    private(set) var end: TimeInterval

    /// The whole clip.
    init(duration: TimeInterval) {
        self.duration = max(0, duration)
        end = self.duration
    }

    /// Whether anything is cut off at either end.
    var isTrimmed: Bool { duration > 0 && (start > 0.01 || end < duration - 0.01) }

    var length: TimeInterval { end - start }

    var range: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
    }

    /// Stays inside the clip and at least `minimumLength` before the end.
    mutating func setStart(_ time: TimeInterval) {
        start = max(0, min(time, end - Self.minimumLength))
    }

    /// Stays inside the clip and at least `minimumLength` after the start.
    mutating func setEnd(_ time: TimeInterval) {
        end = min(duration, max(time, start + Self.minimumLength))
    }
}

/// The editor's two level sliders and mute switches, and how they translate
/// into what is rendered and what is stored in the file.
struct AudioLevels: Equatable {
    /// 150 %.
    static let maximum = 1.5

    var system = 1.0
    var microphone = 1.0
    var systemMuted = false
    var microphoneMuted = false

    init() {}

    /// The controls for a clip saved at these levels. A level of zero comes
    /// back as muted, with the slider left at 100 %.
    init(saved edit: ClipTrimmer.AudioEdit) {
        systemMuted = edit.system == 0
        system = edit.system == 0 ? 1 : edit.system
        microphoneMuted = edit.microphone == 0
        microphone = edit.microphone == 0 ? 1 : edit.microphone
    }

    /// The gains to render with: a muted source is silent whatever its slider says.
    var edit: ClipTrimmer.AudioEdit {
        ClipTrimmer.AudioEdit(system: systemMuted ? 0 : system, microphone: microphoneMuted ? 0 : microphone)
    }
}

extension ClipTrimmer.AudioEdit {
    /// From the levels stored in a clip's `ClipInfo`; a missing entry means 100 %.
    init(stored levels: [String: Double]?) {
        self.init(
            system: levels?[ClipInfo.AudioRole.system.rawValue] ?? 1,
            microphone: levels?[ClipInfo.AudioRole.microphone.rawValue] ?? 1
        )
    }

    /// As stored in a clip's `ClipInfo`.
    var stored: [String: Double] {
        [ClipInfo.AudioRole.system.rawValue: system, ClipInfo.AudioRole.microphone.rawValue: microphone]
    }
}
