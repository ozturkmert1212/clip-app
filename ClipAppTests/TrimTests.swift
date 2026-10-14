import AVFoundation
import XCTest

/// `ClipTrimmer` on a synthetic clip that has both sources as separate tracks
/// and, like real clips, hidden frames before its start.
final class TrimTests: TemporaryDirectoryTestCase {
    private static let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipAppTests-trim-\(UUID().uuidString)", isDirectory: true)
    private static let fixture = Task { try await Synthetic.makeClip(in: fixtureDirectory, seconds: 6) }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: fixtureDirectory)
        super.tearDown()
    }

    /// 2.7 s that start 0.6 s after a keyframe (the clip's own start lies
    /// 0.7 s after one, and keyframes come every 2 s).
    private let range = CMTimeRange(
        start: CMTime(seconds: 1.9, preferredTimescale: 600), end: CMTime(seconds: 4.6, preferredTimescale: 600)
    )
    private let shownFrames = Int(2.7 * Double(Synthetic.fps))
    private let whole = CMTimeRange(start: .zero, end: CMTime(seconds: 6, preferredTimescale: 600))

    /// A copy of the shared clip in this test's own folder: results are
    /// written next to their source.
    private func source(named name: String = "clip") async throws -> URL {
        let copy = directory.appendingPathComponent(name).appendingPathExtension("mp4")
        try FileManager.default.copyItem(at: try await Self.fixture.value, to: copy)
        return copy
    }

    private func trim(
        _ source: URL, range: CMTimeRange? = nil, mode: ClipTrimmer.Mode = .passthrough,
        audio: ClipTrimmer.AudioEdit? = nil, isFullLength: Bool = false, replacingOriginal: Bool = false
    ) async throws -> MediaFile {
        MediaFile(try await ClipTrimmer.trim(
            source, range: range ?? self.range, mode: mode, audio: audio,
            isFullLength: isFullLength, replacingOriginal: replacingOriginal
        ) { _ in })
    }

    private func assertSameRecord(_ file: MediaFile, as original: MediaFile, line: UInt = #line) async {
        let info = await file.info()
        let expected = await original.info()
        XCTAssertNotNil(info, line: line)
        XCTAssertEqual(info?.game, expected?.game, line: line)
        XCTAssertEqual(info?.bundleID, expected?.bundleID, line: line)
        XCTAssertEqual(info?.recorded, expected?.recorded, line: line)
        XCTAssertEqual(info?.audio, [.mix, .system, .microphone], line: line)
    }

    // MARK: - Plain cut

    func testACutHasTheSelectedLengthAndKeepsEverythingElse() async throws {
        let source = try await source()
        let original = MediaFile(source)
        let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int

        let cut = try await trim(source)
        XCTAssertEqual(cut.url.lastPathComponent, "clip (trimmed).mp4")
        let duration = try await cut.duration()
        XCTAssertEqual(duration, 2.7, accuracy: 0.05)
        let codec = try await cut.videoCodec()
        XCTAssertEqual(codec, kCMVideoCodecType_H264)
        let enabled = try await cut.audioEnabled()
        XCTAssertEqual(enabled, [true, false, false])
        await assertSameRecord(cut, as: original)
        await cut.assertDecodes(at: 0)
        await cut.assertDecodes(at: 2.6)
        // The original is not touched.
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int, size)
        XCTAssertEqual(tree(), ["clip (trimmed).mp4", "clip.mp4"])
    }

    func testFurtherCutsGetNumberedNames() async throws {
        let source = try await source()
        _ = try await trim(source)
        let second = try await trim(source)
        let third = try await trim(source)
        XCTAssertEqual(second.url.lastPathComponent, "clip (trimmed 2).mp4")
        XCTAssertEqual(third.url.lastPathComponent, "clip (trimmed 3).mp4")
    }

    func testACutKeepsTheAudioOfItsOwnStretch() async throws {
        let cut = try await trim(try await source())
        for (track, present, absent) in [(1, Synthetic.systemTone, Synthetic.microphoneTone), (2, Synthetic.microphoneTone, Synthetic.systemTone)] {
            let kept = try await cut.level(of: present, inAudioTrack: track)
            let other = try await cut.level(of: absent, inAudioTrack: track)
            XCTAssertEqual(kept, Synthetic.toneLevel, accuracy: 1, "track \(track)")
            XCTAssertLessThan(other, Synthetic.toneLevel - 40, "track \(track)")
        }
    }

    // MARK: - Precise cut

    func testAPreciseCutKeepsLengthSizeAndRecord() async throws {
        let source = try await source()
        let cut = try await trim(source, mode: .reencode)
        let duration = try await cut.duration()
        XCTAssertEqual(duration, 2.7, accuracy: 0.05)
        let codec = try await cut.videoCodec()
        XCTAssertEqual(codec, kCMVideoCodecType_H264)
        let size = try await cut.videoTrack().load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: Synthetic.width, height: Synthetic.height))
        let enabled = try await cut.audioEnabled()
        XCTAssertEqual(enabled, [true, false, false])
        await assertSameRecord(cut, as: MediaFile(source))
        await cut.assertDecodes(at: 0)
    }

    func testAPreciseCutKeepsAtLeastNinetyPercentOfTheSourceBitrate() async throws {
        let source = try await source()
        let sourceRate = try await MediaFile(source).videoTrack().load(.estimatedDataRate)
        let cut = try await trim(source, mode: .reencode)
        let rate = try await cut.videoTrack().load(.estimatedDataRate)
        // The synthetic picture is busy enough for the encoder to spend what it is given.
        XCTAssertGreaterThan(sourceRate, Float(Synthetic.bitrate) * 0.5, "the source itself is too easy to compress to judge by")
        print("Precise cut: \(Int(rate)) bps, source \(Int(sourceRate)) bps (\(Int((rate / sourceRate * 100).rounded())) %)")
        XCTAssertGreaterThanOrEqual(rate, sourceRate * 0.9, "precise cut \(Int(rate)) bps, source \(Int(sourceRate)) bps")
    }

    func testAPlainCutKeepsHiddenFramesAndAPreciseCutDoesNot() async throws {
        let source = try await source()
        // Copying can only start on a keyframe, so the frames from there to the
        // chosen start stay in the file, out of sight.
        let copied = try await trim(source).storedVideoFrames()
        XCTAssertEqual(copied, shownFrames + Int(0.6 * Double(Synthetic.fps)), accuracy: 3)
        let encoded = try await trim(source, mode: .reencode).storedVideoFrames()
        XCTAssertEqual(encoded, shownFrames, accuracy: 2)
    }

    // MARK: - Audio levels

    func testNewLevelsChangeOnlyTheMix() async throws {
        let source = try await source()
        let original = MediaFile(source)
        let edited = try await trim(source, range: whole, audio: ClipTrimmer.AudioEdit(system: 0.5, microphone: 0), isFullLength: true)
        XCTAssertEqual(edited.url.lastPathComponent, "clip (edited).mp4")

        let before = try await original.level(of: Synthetic.systemTone, inAudioTrack: 0)
        let system = try await edited.level(of: Synthetic.systemTone, inAudioTrack: 0)
        let microphone = try await edited.level(of: Synthetic.microphoneTone, inAudioTrack: 0)
        XCTAssertEqual(system - before, -6.02, accuracy: 1, "half the level is 6 dB less")
        XCTAssertLessThan(microphone, Synthetic.toneLevel - 40, "muted")

        // The sources themselves are as they were, so the edit can be redone.
        let systemTrack = try await edited.level(of: Synthetic.systemTone, inAudioTrack: 1)
        let microphoneTrack = try await edited.level(of: Synthetic.microphoneTone, inAudioTrack: 2)
        XCTAssertEqual(systemTrack, Synthetic.toneLevel, accuracy: 1)
        XCTAssertEqual(microphoneTrack, Synthetic.toneLevel, accuracy: 1)

        let enabled = try await edited.audioEnabled()
        XCTAssertEqual(enabled, [true, false, false])
        let duration = try await edited.duration()
        XCTAssertEqual(duration, 6, accuracy: 0.05)
        await assertSameRecord(edited, as: original)
        let info = await edited.info()
        XCTAssertEqual(info?.levels, ["system": 0.5, "microphone": 0])
    }

    func testALevelAboveOneHundredPercentAmplifies() async throws {
        let source = try await source()
        let before = try await MediaFile(source).level(of: Synthetic.microphoneTone, inAudioTrack: 0)
        let edited = try await trim(source, audio: ClipTrimmer.AudioEdit(system: 1, microphone: AudioLevels.maximum))
        let microphone = try await edited.level(of: Synthetic.microphoneTone, inAudioTrack: 0)
        let system = try await edited.level(of: Synthetic.systemTone, inAudioTrack: 0)
        XCTAssertEqual(microphone - before, 3.52, accuracy: 1, "150 % is 3.5 dB more")
        XCTAssertEqual(system, Synthetic.toneLevel, accuracy: 1)
        let duration = try await edited.duration()
        XCTAssertEqual(duration, 2.7, accuracy: 0.05)
    }

    func testLevelsAndAPreciseCutTogether() async throws {
        let edited = try await trim(try await source(), mode: .reencode, audio: ClipTrimmer.AudioEdit(system: 0, microphone: 1))
        let system = try await edited.level(of: Synthetic.systemTone, inAudioTrack: 0)
        let microphone = try await edited.level(of: Synthetic.microphoneTone, inAudioTrack: 0)
        XCTAssertLessThan(system, Synthetic.toneLevel - 40)
        XCTAssertEqual(microphone, Synthetic.toneLevel, accuracy: 1)
        let duration = try await edited.duration()
        XCTAssertEqual(duration, 2.7, accuracy: 0.05)
        let enabled = try await edited.audioEnabled()
        XCTAssertEqual(enabled, [true, false, false])
    }

    func testAnEditedClipCanBeEditedAgainFromTheOriginalSources() async throws {
        let first = try await trim(try await source(), range: whole, audio: ClipTrimmer.AudioEdit(system: 0, microphone: 0), isFullLength: true)
        let second = try await trim(first.url, range: whole, audio: ClipTrimmer.AudioEdit(system: 1, microphone: 1), isFullLength: true)
        let system = try await second.level(of: Synthetic.systemTone, inAudioTrack: 0)
        let microphone = try await second.level(of: Synthetic.microphoneTone, inAudioTrack: 0)
        XCTAssertEqual(system, Synthetic.toneLevel, accuracy: 1)
        XCTAssertEqual(microphone, Synthetic.toneLevel, accuracy: 1)
    }

    func testLevelsNeedSeparateSourceTracks() async throws {
        let single = try await Synthetic.makeClip(in: directory, name: "single", seconds: 2, keepStems: false)
        do {
            _ = try await trim(single, range: CMTimeRange(start: .zero, end: CMTime(seconds: 1, preferredTimescale: 600)), audio: ClipTrimmer.AudioEdit(system: 0.5, microphone: 1))
            XCTFail("A clip with only a mixed track cannot be re-balanced")
        } catch ClipTrimmer.TrimError.unsupported {
            for _ in 0..<50 where tree().count > 1 { try await Task.sleep(nanoseconds: 100_000_000) }
            XCTAssertEqual(tree(), ["single.mp4"], "nothing half-written is left")
        }
    }

    // MARK: - Replacing the original

    func testReplacingPutsTheResultWhereTheOriginalWas() async throws {
        let source = try await source()
        let created = try source.resourceValues(forKeys: [.creationDateKey]).creationDate
        let result = try await trim(source, audio: ClipTrimmer.AudioEdit(system: 1, microphone: 0), replacingOriginal: true)
        XCTAssertEqual(result.url, source)
        let duration = try await result.duration()
        XCTAssertEqual(duration, 2.7, accuracy: 0.05)
        let microphone = try await result.level(of: Synthetic.microphoneTone, inAudioTrack: 0)
        XCTAssertLessThan(microphone, Synthetic.toneLevel - 40)
        for _ in 0..<50 where tree().count > 1 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(tree(), ["clip.mp4"], "no temporary file is left")
        XCTAssertEqual(try source.resourceValues(forKeys: [.creationDateKey]).creationDate, created)
    }

    func testACancelledReplacementLeavesTheOriginalUntouched() async throws {
        let source = try await source()
        let before = try Data(contentsOf: source)
        let range = whole
        let task = Task {
            try await ClipTrimmer.trim(source, range: range, mode: .reencode, replacingOriginal: true) { _ in }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("The cancelled trim should not have finished")
        } catch is CancellationError {}
        for _ in 0..<50 where tree().count > 1 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(tree(), ["clip.mp4"])
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testAMissingSourceFailsWithoutLeavingAFile() async throws {
        let missing = directory.appendingPathComponent("gone.mp4")
        do {
            _ = try await trim(missing)
            XCTFail("There is nothing to trim")
        } catch {}
        XCTAssertEqual(tree(), [])
    }
}
