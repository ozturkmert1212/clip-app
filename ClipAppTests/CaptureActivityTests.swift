import XCTest

final class CaptureActivityTests: XCTestCase {
    private let off = CaptureActivity(isClipping: false, isRecording: false)
    private let clipping = CaptureActivity(isClipping: true, isRecording: false)
    private let recording = CaptureActivity(isClipping: false, isRecording: true)
    private let both = CaptureActivity(isClipping: true, isRecording: true)

    private var all: [CaptureActivity] { [off, clipping, recording, both] }

    // MARK: - Stored setting

    func testDoesNotStartAtLaunchWithoutAStoredValue() throws {
        let suite = "ClipAppTests.CaptureActivity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(CaptureActivity.startsAtLaunchDefault)
        XCTAssertFalse(CaptureActivity.storedStartsAtLaunch(in: defaults))
        defaults.set(true, forKey: CaptureActivity.startsAtLaunchKey)
        XCTAssertTrue(CaptureActivity.storedStartsAtLaunch(in: defaults))
        defaults.set(false, forKey: CaptureActivity.startsAtLaunchKey)
        XCTAssertFalse(CaptureActivity.storedStartsAtLaunch(in: defaults))
        defaults.set("yes", forKey: CaptureActivity.startsAtLaunchKey)
        XCTAssertFalse(CaptureActivity.storedStartsAtLaunch(in: defaults))
    }

    func testStartsWithEverythingOff() {
        XCTAssertEqual(CaptureActivity(), off)
    }

    // MARK: - States

    func testNothingOn() {
        XCTAssertFalse(off.streamRuns)
        XCTAssertFalse(off.fillsBuffer)
        XCTAssertFalse(off.canSaveClip)
        XCTAssertEqual(off.primaryAction, .startClipping)
        XCTAssertFalse(off.offersStopClipping)
        XCTAssertEqual(off.icon(captureWorks: true), .dimmed)
        XCTAssertEqual(off.icon(captureWorks: false), .dimmed)
    }

    func testClippingOnly() {
        XCTAssertTrue(clipping.streamRuns)
        XCTAssertTrue(clipping.fillsBuffer)
        XCTAssertTrue(clipping.canSaveClip)
        XCTAssertEqual(clipping.primaryAction, .saveClip)
        XCTAssertTrue(clipping.offersStopClipping)
        XCTAssertEqual(clipping.icon(captureWorks: true), .normal)
        // On, but failing or without permission.
        XCTAssertEqual(clipping.icon(captureWorks: false), .dimmed)
    }

    func testRecordingOnly() {
        XCTAssertTrue(recording.streamRuns)
        XCTAssertFalse(recording.fillsBuffer)
        XCTAssertFalse(recording.canSaveClip)
        XCTAssertEqual(recording.primaryAction, .startClipping)
        XCTAssertFalse(recording.offersStopClipping)
        XCTAssertEqual(recording.icon(captureWorks: true), .recording)
        XCTAssertEqual(recording.icon(captureWorks: false), .recording)
    }

    func testClippingAndRecording() {
        XCTAssertTrue(both.streamRuns)
        XCTAssertTrue(both.fillsBuffer)
        XCTAssertTrue(both.canSaveClip)
        XCTAssertEqual(both.primaryAction, .saveClip)
        XCTAssertTrue(both.offersStopClipping)
        XCTAssertEqual(both.icon(captureWorks: true), .recording)
        XCTAssertEqual(both.icon(captureWorks: false), .recording)
    }

    // MARK: - Transitions

    func testStartAndStopClipping() {
        XCTAssertEqual(off.effects(to: clipping), [.startStream, .fillBuffer])
        XCTAssertEqual(clipping.effects(to: off), [.clearBuffer, .stopStream])
    }

    func testStopClippingDuringARecordingKeepsTheStream() {
        XCTAssertEqual(both.effects(to: recording), [.clearBuffer])
        XCTAssertEqual(recording.effects(to: both), [.fillBuffer])
    }

    func testARecordingOnItsOwnStartsAndStopsTheStream() {
        XCTAssertEqual(off.effects(to: recording), [.startStream])
        XCTAssertEqual(recording.effects(to: off), [.stopStream])
    }

    func testARecordingDuringClippingLeavesStreamAndBufferAlone() {
        XCTAssertEqual(clipping.effects(to: both), [])
        XCTAssertEqual(both.effects(to: clipping), [])
    }

    func testBothEndingAtOnce() {
        XCTAssertEqual(both.effects(to: off), [.clearBuffer, .stopStream])
        XCTAssertEqual(off.effects(to: both), [.startStream, .fillBuffer])
    }

    func testClippingAndRecordingSwappingPlaces() {
        XCTAssertEqual(clipping.effects(to: recording), [.clearBuffer])
        XCTAssertEqual(recording.effects(to: clipping), [.fillBuffer])
    }

    // MARK: - Start/Stop Clipping shortcut

    func testTheShortcutFlipsClippingAndLeavesTheRecording() {
        XCTAssertEqual(off.togglingClipping, clipping)
        XCTAssertEqual(clipping.togglingClipping, off)
        XCTAssertEqual(recording.togglingClipping, both)
        XCTAssertEqual(both.togglingClipping, recording)
        for state in all {
            XCTAssertEqual(state.togglingClipping.togglingClipping, state, "\(state)")
        }
    }

    /// The same transitions as the Start and Stop Clipping buttons.
    func testTheShortcutTakesTheButtonsEffects() {
        XCTAssertEqual(off.effects(to: off.togglingClipping), [.startStream, .fillBuffer])
        XCTAssertEqual(clipping.effects(to: clipping.togglingClipping), [.clearBuffer, .stopStream])
        // During a recording the stream stays, only the buffer goes and comes.
        XCTAssertEqual(both.effects(to: both.togglingClipping), [.clearBuffer])
        XCTAssertEqual(recording.effects(to: recording.togglingClipping), [.fillBuffer])
    }

    /// Once the shortcut has stopped clipping, Save Last N Seconds only says
    /// that clipping is off again, with or without a recording.
    func testSavingIsRefusedAgainAfterTheShortcutStopsClipping() {
        for state in [clipping, both] {
            let stopped = state.togglingClipping
            XCTAssertFalse(stopped.canSaveClip, "\(state)")
            XCTAssertEqual(stopped.primaryAction, .startClipping, "\(state)")
            XCTAssertFalse(stopped.offersStopClipping, "\(state)")
        }
        XCTAssertTrue(off.togglingClipping.canSaveClip)
        XCTAssertTrue(recording.togglingClipping.canSaveClip)
    }

    func testNoChangeHasNoEffect() {
        for state in all {
            XCTAssertEqual(state.effects(to: state), [], "\(state)")
        }
    }

    /// Whatever the path, applying the effects leaves the stream and the
    /// buffer exactly where the new state says they should be.
    func testEffectsAlwaysLeadToTheTargetState() {
        for from in all {
            for to in all {
                var streamRuns = from.streamRuns
                var fillsBuffer = from.fillsBuffer
                var bufferCleared = false
                for effect in from.effects(to: to) {
                    switch effect {
                    case .startStream:
                        XCTAssertFalse(streamRuns, "\(from) -> \(to)")
                        streamRuns = true
                    case .stopStream:
                        XCTAssertTrue(streamRuns, "\(from) -> \(to)")
                        // The buffer is closed before the stream goes.
                        XCTAssertFalse(fillsBuffer, "\(from) -> \(to)")
                        streamRuns = false
                    case .fillBuffer:
                        XCTAssertTrue(streamRuns, "\(from) -> \(to)")
                        fillsBuffer = true
                    case .clearBuffer:
                        fillsBuffer = false
                        bufferCleared = true
                    }
                }
                XCTAssertEqual(streamRuns, to.streamRuns, "\(from) -> \(to)")
                XCTAssertEqual(fillsBuffer, to.fillsBuffer, "\(from) -> \(to)")
                XCTAssertEqual(bufferCleared, from.isClipping && !to.isClipping, "\(from) -> \(to)")
            }
        }
    }
}
