import AVFoundation
import XCTest

/// `RecordingWriter` fed live from the real encoder, with synthetic input.
final class RecordingTests: TemporaryDirectoryTestCase {
    private var failures: [RecordingWriter.RecordingError] = []
    private let failureLock = NSLock()

    private func noteFailure(_ error: RecordingWriter.RecordingError) {
        failureLock.lock()
        failures.append(error)
        failureLock.unlock()
    }

    private struct Session {
        let writer: RecordingWriter
        /// Host time of the first recorded frame.
        let base: CMTime
        let encoder: EncoderPipeline
        let frames: Int
        /// Frame index at which the recording started.
        let offset: Int
        var end: CMTime { Synthetic.frameTime(offset + frames, from: base) }
    }

    /// The encoder's output goes to whichever writer is current, as in the app.
    private final class Tap: @unchecked Sendable {
        private let lock = NSLock()
        private var current: RecordingWriter?
        var writer: RecordingWriter? {
            get { lock.lock(); defer { lock.unlock() }; return current }
            set { lock.lock(); current = newValue; lock.unlock() }
        }
    }

    /// Records `seconds` of synthetic input. `microphone` says, per second
    /// of the recording, whether the microphone delivers during it.
    private func record(
        seconds: Double, sources: [AudioTrack] = [.system, .microphone], keepStems: Bool = true,
        microphone delivers: @escaping (Double) -> Bool = { _ in true }
    ) async throws -> Session {
        let probe = RingBuffer(duration: 2, byteLimit: .max)
        let tap = Tap()
        let encoder = EncoderPipeline(fps: Synthetic.fps, bitrate: Synthetic.bitrate) { sample in
            probe.append(sample)
            tap.writer?.appendVideo(sample)
        }
        let base = CMClockGetTime(CMClockGetHostTimeClock())
        // A little footage first, as in the app: the pipeline's format is taken from it.
        let offset = 30
        for index in 0..<offset { encoder.encode(Synthetic.frame(index, at: Synthetic.frameTime(index, from: base))) }
        try await Synthetic.waitForEncoder(probe, until: Synthetic.frameTime(offset - 1, from: base))

        let writer = try RecordingWriter(
            url: directory.appendingPathComponent("recording.mp4"),
            videoFormat: try XCTUnwrap(probe.formats().video),
            audioFormats: sources.map { ($0, FakeSamples.audioFormat) },
            keepStems: keepStems,
            info: ClipInfo(game: "Test Game", bundleID: "com.example.testgame", recorded: Date())
        ) { [weak self] in self?.noteFailure($0) }
        tap.writer = writer
        encoder.requestKeyframe()

        let frames = Int(seconds * Double(Synthetic.fps))
        let perFrame = Synthetic.sampleRate / Synthetic.fps
        var system = offset * perFrame, microphone = offset * perFrame
        for index in offset..<(offset + frames) {
            encoder.encode(Synthetic.frame(index, at: Synthetic.frameTime(index, from: base)))
            let upTo = (index + 1) * perFrame
            while system + 1024 <= upTo {
                if sources.contains(.system) {
                    writer.appendAudio(Synthetic.tone(Synthetic.systemTone, start: system, frames: 1024, base: base), from: .system)
                }
                system += 1024
            }
            while microphone + 480 <= upTo {
                let second = Double(microphone - offset * perFrame) / Double(Synthetic.sampleRate)
                if sources.contains(.microphone), delivers(second) {
                    writer.appendAudio(Synthetic.tone(Synthetic.microphoneTone, start: microphone, frames: 480, base: base), from: .microphone)
                }
                microphone += 480
            }
            // Roughly eight times real time: fast, but still a stream.
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await Synthetic.waitForEncoder(probe, until: Synthetic.frameTime(offset + frames - 1, from: base))
        tap.writer = nil
        return Session(writer: writer, base: base, encoder: encoder, frames: frames, offset: offset)
    }

    private func finished(_ session: Session, at end: CMTime? = nil) async throws -> MediaFile {
        let outcome = await session.writer.finish(at: end ?? session.end)
        XCTAssertNil(outcome.error)
        return MediaFile(try XCTUnwrap(outcome.url))
    }

    // MARK: - A finished recording

    func testARecordingHasTheClipTrackLayout() async throws {
        let session = try await record(seconds: 4)
        let outcome = await session.writer.finish(at: session.end)
        XCTAssertNil(outcome.error)
        let file = MediaFile(try XCTUnwrap(outcome.url))

        let duration = try await file.duration()
        XCTAssertEqual(duration, 4, accuracy: 0.08)
        let codec = try await file.videoCodec()
        XCTAssertEqual(codec, kCMVideoCodecType_H264)
        let enabled = try await file.audioEnabled()
        XCTAssertEqual(enabled, [true, false, false])
        let info = await file.info()
        XCTAssertEqual(info?.audio, [.mix, .system, .microphone])
        XCTAssertEqual(info?.game, "Test Game")
        XCTAssertEqual(info?.bundleID, "com.example.testgame")
        await file.assertDecodes(at: 0)
        await file.assertDecodes(at: 3.9)
        XCTAssertTrue(failures.isEmpty)
    }

    func testEachTrackOfARecordingHoldsWhatItShould() async throws {
        let session = try await record(seconds: 4)
        let file = try await finished(session)
        let expected: [(track: Int, system: Bool, microphone: Bool)] = [(0, true, true), (1, true, false), (2, false, true)]
        for row in expected {
            let system = try await file.level(of: Synthetic.systemTone, inAudioTrack: row.track)
            let microphone = try await file.level(of: Synthetic.microphoneTone, inAudioTrack: row.track)
            if row.system { XCTAssertEqual(system, Synthetic.toneLevel, accuracy: 1, "track \(row.track)") }
            else { XCTAssertLessThan(system, Synthetic.toneLevel - 40, "track \(row.track)") }
            if row.microphone { XCTAssertEqual(microphone, Synthetic.toneLevel, accuracy: 1, "track \(row.track)") }
            else { XCTAssertLessThan(microphone, Synthetic.toneLevel - 40, "track \(row.track)") }
        }
    }

    func testASourceThatStartsLateOrPausesIsFilledWithSilence() async throws {
        // The microphone joins after 1 s and is gone from 3 s to 4 s.
        let session = try await record(seconds: 6) { $0 >= 1 && !($0 >= 3 && $0 < 4) }
        let file = try await finished(session)
        let quiet = Synthetic.toneLevel - 40
        let beforeJoining = try await file.level(of: Synthetic.microphoneTone, inAudioTrack: 2, from: 0.15, to: 0.85)
        let afterJoining = try await file.level(of: Synthetic.microphoneTone, inAudioTrack: 2, from: 1.5, to: 2.5)
        let duringPause = try await file.level(of: Synthetic.microphoneTone, inAudioTrack: 2, from: 3.15, to: 3.85)
        let afterPause = try await file.level(of: Synthetic.microphoneTone, inAudioTrack: 2, from: 4.5, to: 5.5)
        XCTAssertLessThan(beforeJoining, quiet)
        XCTAssertEqual(afterJoining, Synthetic.toneLevel, accuracy: 1)
        XCTAssertLessThan(duringPause, quiet)
        XCTAssertEqual(afterPause, Synthetic.toneLevel, accuracy: 1)
        // The other source is not held back or cut by it.
        let systemDuringPause = try await file.level(of: Synthetic.systemTone, inAudioTrack: 1, from: 3.15, to: 3.85)
        XCTAssertEqual(systemDuringPause, Synthetic.toneLevel, accuracy: 1)
        let duration = try await file.duration()
        XCTAssertEqual(duration, 6, accuracy: 0.08)
    }

    func testOneSourceGivesOneOrdinaryTrack() async throws {
        let session = try await record(seconds: 2, sources: [.system])
        let file = try await finished(session)
        let enabled = try await file.audioEnabled()
        XCTAssertEqual(enabled, [true])
        let info = await file.info()
        XCTAssertEqual(info?.audio, [.system])
        let system = try await file.level(of: Synthetic.systemTone, inAudioTrack: 0)
        XCTAssertEqual(system, Synthetic.toneLevel, accuracy: 1)
    }

    func testWithoutSeparateTracksOnlyTheMixIsRecorded() async throws {
        let session = try await record(seconds: 2, keepStems: false)
        let file = try await finished(session)
        let enabled = try await file.audioEnabled()
        XCTAssertEqual(enabled, [true])
        let info = await file.info()
        XCTAssertEqual(info?.audio, [.mix])
        let system = try await file.level(of: Synthetic.systemTone, inAudioTrack: 0)
        let microphone = try await file.level(of: Synthetic.microphoneTone, inAudioTrack: 0)
        XCTAssertEqual(system, Synthetic.toneLevel, accuracy: 1)
        XCTAssertEqual(microphone, Synthetic.toneLevel, accuracy: 1)
    }

    func testTheLastFrameIsHeldUntilTheRecordingEnds() async throws {
        // A static screen: no frame arrives for the last second.
        let session = try await record(seconds: 2)
        let end = session.end + CMTime(seconds: 1, preferredTimescale: 600)
        let file = try await finished(session, at: end)
        let duration = try await file.duration()
        XCTAssertEqual(duration, 3, accuracy: 0.08)
        let video = try await file.videoTrack().load(.timeRange)
        XCTAssertEqual(video.duration.seconds, 3, accuracy: 0.08)
        await file.assertDecodes(at: 2.9)
    }

    // MARK: - Recordings that do not end normally

    func testAnUnfinishedRecordingIsAlreadyPlayable() async throws {
        // What a crash would leave behind: the file as it is on disk while the
        // writer is still open, once the first fragments are out.
        let session = try await record(seconds: 11.5)
        let url = session.writer.url
        var playable = 0.0
        for _ in 0..<30 {
            playable = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            if playable >= 5 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThanOrEqual(playable, 5, "at least the first fragment")
        await MediaFile(url).assertDecodes(at: 4)
        _ = await session.writer.finish(at: session.end)
    }

    func testAChangeOfCaptureSizeEndsTheRecordingButKeepsTheFile() async throws {
        let session = try await record(seconds: 2)
        // A frame of another size, as after switching to another display.
        let other = FakeSamples.video(at: session.end.seconds, keyframe: true, format: FakeSamples.videoFormat(width: 320, height: 200))
        session.writer.appendVideo(other)
        let outcome = await session.writer.finish(at: session.end)
        guard case .formatChanged = outcome.error else { return XCTFail("expected formatChanged, got \(String(describing: outcome.error))") }
        XCTAssertEqual(failures.count, 1)
        let file = MediaFile(try XCTUnwrap(outcome.url))
        let duration = try await file.duration()
        XCTAssertEqual(duration, 2, accuracy: 0.08)
        await file.assertDecodes(at: 1)
    }

    func testARecordingWithoutAnyFrameLeavesNoFile() async throws {
        let format = FakeSamples.videoFormat(width: Int32(Synthetic.width), height: Int32(Synthetic.height))
        let writer = try RecordingWriter(
            url: directory.appendingPathComponent("empty.mp4"), videoFormat: format,
            audioFormats: [(.system, FakeSamples.audioFormat)], keepStems: true,
            info: ClipInfo(game: "Test Game", bundleID: nil, recorded: Date())
        ) { _ in }
        writer.appendAudio(Synthetic.tone(Synthetic.systemTone, start: 0, frames: 1024, base: .zero), from: .system)
        let outcome = await writer.finish(at: CMTime(seconds: 5, preferredTimescale: 600))
        XCTAssertNil(outcome.url)
        guard case .noFrames = outcome.error else { return XCTFail("expected noFrames, got \(String(describing: outcome.error))") }
        XCTAssertEqual(tree(), [])
    }
}
