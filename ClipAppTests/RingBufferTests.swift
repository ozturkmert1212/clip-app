import CoreMedia
import XCTest

final class RingBufferTests: XCTestCase {
    private let format = FakeSamples.videoFormat()
    private let time = FakeSamples.time

    private func seconds(_ time: CMTime?) -> Double { time?.seconds ?? .nan }

    // MARK: - Trimming by GOP

    func testNothingIsKeptBeforeTheFirstKeyframe() {
        let buffer = RingBuffer(duration: 4, byteLimit: .max)
        for index in 0..<10 {
            buffer.append(FakeSamples.video(at: Double(index) / 30, keyframe: false, format: format))
        }
        XCTAssertNil(buffer.videoStatus().oldest)
        XCTAssertNil(buffer.snapshot(endingAt: time(1)))
    }

    func testOldFootageIsDroppedAWholeGOPAtATime() {
        let buffer = RingBuffer(duration: 4, byteLimit: .max)
        FakeSamples.fill(buffer, seconds: 10, format: format)
        // The keyframe at 8 s made everything before the one at 4 s go.
        let status = buffer.videoStatus()
        XCTAssertEqual(seconds(status.oldest), 4, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(status.span, 4)
        XCTAssertLessThan(status.span, 6)
        XCTAssertEqual(status.bytes, Int(status.span * 30 + 1.5) * 1000)
        XCTAssertFalse(status.isByteLimited)
    }

    func testTheBufferNeverGetsShorterThanItsDuration() {
        let buffer = RingBuffer(duration: 4, byteLimit: .max)
        for index in 0..<(20 * 30) {
            buffer.append(FakeSamples.video(at: Double(index) / 30, keyframe: index % 60 == 0, format: format))
            let status = buffer.videoStatus()
            guard let oldest = status.oldest, Double(index) / 30 >= 4 else { continue }
            XCTAssertLessThanOrEqual(oldest.seconds, Double(index) / 30 - 4 + 0.001, "at frame \(index)")
            XCTAssertEqual(oldest.seconds.truncatingRemainder(dividingBy: 2), 0, accuracy: 0.001, "starts on a keyframe")
        }
    }

    func testAShorterDurationAppliesAtTheNextKeyframe() {
        let buffer = RingBuffer(duration: 8, byteLimit: .max)
        FakeSamples.fill(buffer, seconds: 9, format: format)
        XCTAssertEqual(seconds(buffer.videoStatus().oldest), 0, accuracy: 0.001)
        buffer.setDuration(2)
        FakeSamples.fill(buffer, from: 9, seconds: 0.9, gop: 100, format: format)
        buffer.append(FakeSamples.video(at: 10, keyframe: true, format: format))
        XCTAssertEqual(seconds(buffer.videoStatus().oldest), 8, accuracy: 0.001)
    }

    // MARK: - Snapshots

    func testASnapshotStartsOnTheKeyframeBeforeItsWindow() throws {
        let buffer = RingBuffer(duration: 4, byteLimit: .max)
        FakeSamples.fill(buffer, seconds: 10, format: format)
        let snapshot = try XCTUnwrap(buffer.snapshot(endingAt: time(9.5)))
        XCTAssertEqual(snapshot.startTime.seconds, 5.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.endTime.seconds, 9.5, accuracy: 0.001)
        let first = try XCTUnwrap(snapshot.video.first)
        XCTAssertTrue(RingBuffer.isKeyframe(first))
        XCTAssertEqual(first.presentationTimeStamp.seconds, 4, accuracy: 0.001)
    }

    func testASnapshotOfAStaticScreenStillCoversTheWindow() throws {
        // No frames after 3 s; the request comes at 20 s.
        let buffer = RingBuffer(duration: 4, byteLimit: .max)
        FakeSamples.fill(buffer, seconds: 3, format: format)
        let snapshot = try XCTUnwrap(buffer.snapshot(endingAt: time(20)))
        XCTAssertEqual(snapshot.startTime.seconds, 16, accuracy: 0.001)
        XCTAssertEqual(snapshot.endTime.seconds, 20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.video.first).presentationTimeStamp.seconds, 2, accuracy: 0.001)
    }

    func testAYoungBufferGivesAShorterSnapshot() throws {
        let buffer = RingBuffer(duration: 30, byteLimit: .max)
        FakeSamples.fill(buffer, from: 100, seconds: 5, format: format)
        let snapshot = try XCTUnwrap(buffer.snapshot(endingAt: time(105)))
        XCTAssertEqual(snapshot.startTime.seconds, 100, accuracy: 0.001)
    }

    // MARK: - Byte limit

    func testTheByteLimitDropsTheOldestGOPsWhateverTheirAge() {
        // One GOP is 60 frames of 1000 bytes; the duration alone would keep them all.
        let buffer = RingBuffer(duration: 60, byteLimit: 100_000)
        FakeSamples.fill(buffer, seconds: 10, format: format)
        let status = buffer.videoStatus()
        XCTAssertLessThanOrEqual(status.bytes, 100_000)
        XCTAssertTrue(status.isByteLimited)
        XCTAssertEqual(seconds(status.oldest), 8, accuracy: 0.001)
        XCTAssertLessThan(status.span, 60)
    }

    func testTheGOPBeingFilledSurvivesEvenAboveTheLimit() throws {
        let buffer = RingBuffer(duration: 60, byteLimit: 10_000)
        FakeSamples.fill(buffer, seconds: 3.9, format: format)
        let status = buffer.videoStatus()
        XCTAssertEqual(seconds(status.oldest), 2, accuracy: 0.001)
        XCTAssertGreaterThan(status.bytes, 10_000)
        let first = try XCTUnwrap(buffer.snapshot(endingAt: time(3.9))?.video.first)
        XCTAssertTrue(RingBuffer.isKeyframe(first))
    }

    func testTheLimitStopsCountingOnceTheFullDurationFitsAgain() {
        let buffer = RingBuffer(duration: 4, byteLimit: 100_000)
        FakeSamples.fill(buffer, seconds: 6, format: format)
        XCTAssertTrue(buffer.videoStatus().isByteLimited)
        // Small frames from here on: 4 s of them fit under the limit.
        FakeSamples.fill(buffer, from: 6, seconds: 12, bytes: 100, format: format)
        let status = buffer.videoStatus()
        XCTAssertFalse(status.isByteLimited)
        XCTAssertGreaterThanOrEqual(status.span, 4)
    }

    func testALowerLimitTakesEffectOnTheNextFrame() {
        let buffer = RingBuffer(duration: 60, byteLimit: .max)
        FakeSamples.fill(buffer, seconds: 10, format: format)
        XCTAssertEqual(buffer.videoStatus().bytes, 300_000)
        buffer.setByteLimit(100_000)
        buffer.append(FakeSamples.video(at: 10, keyframe: true, format: format))
        XCTAssertLessThanOrEqual(buffer.videoStatus().bytes, 100_000)
    }

    // MARK: - Formats

    func testAResolutionChangeDropsTheOldFootage() {
        let buffer = RingBuffer(duration: 30, byteLimit: .max)
        FakeSamples.fill(buffer, seconds: 5, format: format)
        let larger = FakeSamples.videoFormat(width: 1920, height: 1080)
        buffer.append(FakeSamples.video(at: 5, keyframe: true, format: larger))
        let status = buffer.videoStatus()
        XCTAssertEqual(seconds(status.oldest), 5, accuracy: 0.001)
        XCTAssertEqual(status.bytes, 1000)
        XCTAssertTrue(CMFormatDescriptionEqual(buffer.formats().video, otherFormatDescription: larger))
    }

    // MARK: - Audio

    func testASnapshotCarriesOnlyTheAudioThatOverlapsIt() throws {
        let buffer = RingBuffer(duration: 4, byteLimit: .max)
        FakeSamples.fill(buffer, seconds: 10, format: format)
        for index in 0..<100 { buffer.append(FakeSamples.audio(at: Double(index) / 10), to: .system) }
        let snapshot = try XCTUnwrap(buffer.snapshot(endingAt: time(9.55)))
        let audio = try XCTUnwrap(snapshot.audio[.system])
        XCTAssertNil(snapshot.audio[.microphone])
        // 0.1 s buffers; the window is 5.55 s to 9.55 s.
        XCTAssertEqual(try XCTUnwrap(audio.first).presentationTimeStamp.seconds, 5.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(audio.last).presentationTimeStamp.seconds, 9.5, accuracy: 0.001)
    }

    func testOldAudioIsPruned() throws {
        let buffer = RingBuffer(duration: 4, byteLimit: .max)
        FakeSamples.fill(buffer, seconds: 30, format: format)
        for index in 0..<300 { buffer.append(FakeSamples.audio(at: Double(index) / 10), to: .microphone) }
        // Asking for a window that reaches back to the start shows what is left.
        buffer.setDuration(30)
        let audio = try XCTUnwrap(buffer.snapshot(endingAt: time(30))?.audio[.microphone])
        let oldest = try XCTUnwrap(audio.first).presentationTimeStamp.seconds
        XCTAssertGreaterThan(oldest, 30 - 4 - 2.5)
        XCTAssertLessThanOrEqual(oldest, 30 - 4)
    }

    func testRemovingASourceAndResetting() throws {
        let buffer = RingBuffer(duration: 4, byteLimit: .max)
        FakeSamples.fill(buffer, seconds: 3, format: format)
        buffer.append(FakeSamples.audio(at: 1), to: .system)
        buffer.append(FakeSamples.audio(at: 1), to: .microphone)
        XCTAssertEqual(buffer.formats().audio.count, 2)

        buffer.removeAudio(.microphone)
        let snapshot = try XCTUnwrap(buffer.snapshot(endingAt: time(3)))
        XCTAssertNotNil(snapshot.audio[.system])
        XCTAssertNil(snapshot.audio[.microphone])

        buffer.reset()
        XCTAssertNil(buffer.snapshot(endingAt: time(3)))
        XCTAssertEqual(buffer.videoStatus().bytes, 0)
        XCTAssertTrue(buffer.formats().audio.isEmpty)
    }
}
