import Foundation

/// The two things the user turns on and off: clipping (the replay buffer)
/// and a recording, and everything that follows from them: whether the
/// capture stream runs, whether the replay buffer fills, what the controls
/// offer and how the menu bar icon looks. Plain values, so every combination
/// can be tested without a stream.
///
/// The stream runs while either is on and stops when both are off, which
/// also takes the system's screen recording indicator away. The buffer only
/// fills while clipping is on; turning clipping off empties it, even while a
/// recording keeps the stream running.
struct CaptureActivity: Equatable {
    /// Settings > General > Start clipping when ClipApp opens; off unless the
    /// user turns it on, a launch as a login item included.
    static let startsAtLaunchKey = "startClippingAtLaunch"
    static let startsAtLaunchDefault = false

    var isClipping = false
    /// Set from the moment a recording is asked for: the stream has to run
    /// before the recording's file can be set up.
    var isRecording = false

    /// What a change of activity asks of the pipeline, in this order.
    enum Effect: Equatable {
        /// Stop feeding the replay buffer and drop what it holds.
        case clearBuffer
        /// Start feeding the replay buffer with what the stream delivers.
        case fillBuffer
        case startStream
        case stopStream
    }

    /// The big button: start clipping, or save once it is on.
    enum PrimaryAction: Equatable {
        case startClipping
        case saveClip
    }

    enum Icon: Equatable {
        /// Full strength, colored by the menu bar.
        case normal
        /// Half opacity: nothing is being kept, or capture is not working.
        case dimmed
        /// With the red dot.
        case recording
    }

    /// The stored setting, `startsAtLaunchDefault` when there is none.
    static func storedStartsAtLaunch(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: startsAtLaunchKey) as? Bool ?? startsAtLaunchDefault
    }

    var streamRuns: Bool { isClipping || isRecording }
    var fillsBuffer: Bool { isClipping }
    /// A clip needs a buffer; with clipping off the shortcut only explains why.
    var canSaveClip: Bool { isClipping }
    var primaryAction: PrimaryAction { isClipping ? .saveClip : .startClipping }
    /// Next to Save in the window and below it in the menu.
    var offersStopClipping: Bool { isClipping }

    /// `captureWorks`: the permission is there and the stream is running or
    /// on its way, not failed.
    func icon(captureWorks: Bool) -> Icon {
        if isRecording { return .recording }
        return isClipping && captureWorks ? .normal : .dimmed
    }

    /// What moving from `self` to `next` takes. The buffer is closed before
    /// the stream stops and opened after it starts.
    func effects(to next: CaptureActivity) -> [Effect] {
        var effects: [Effect] = []
        if fillsBuffer, !next.fillsBuffer { effects.append(.clearBuffer) }
        if !streamRuns, next.streamRuns { effects.append(.startStream) }
        if streamRuns, !next.streamRuns { effects.append(.stopStream) }
        if !fillsBuffer, next.fillsBuffer { effects.append(.fillBuffer) }
        return effects
    }
}
