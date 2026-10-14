import AVFoundation
import XCTest

/// Clips as `ClipWriter` writes them, from synthetic input run through the
/// real encoder and ring buffer.
final class ClipFileTests: TemporaryDirectoryTestCase {
    private static let seconds = 6.0
    private static let fixtureDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipAppTests-clip-\(UUID().uuidString)", isDirectory: true)
    /// One clip with both sources and separate tracks, shared by the tests that only read it.
    private static let fixture = Task { try await Synthetic.makeClip(in: fixtureDirectory, seconds: seconds) }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: fixtureDirectory)
        super.tearDown()
    }

    private func clip() async throws -> MediaFile { MediaFile(try await Self.fixture.value) }

    // MARK: - Container

    func testTheClipIsAsLongAsTheBuffer() async throws {
        let file = try await clip()
        let duration = try await file.duration()
        XCTAssertEqual(duration, Self.seconds, accuracy: 0.05)
        for track in try await file.asset.load(.tracks) {
            let range = try await track.load(.timeRange)
            XCTAssertEqual(range.start.seconds, 0, accuracy: 0.03)
            XCTAssertEqual(range.duration.seconds, Self.seconds, accuracy: 0.05)
        }
    }

    func testTheVideoIsH264AtTheInputSize() async throws {
        let file = try await clip()
        let codec = try await file.videoCodec()
        XCTAssertEqual(codec, kCMVideoCodecType_H264)
        let size = try await file.videoTrack().load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: Synthetic.width, height: Synthetic.height))
    }

    func testTheClipPlaysFromItsFirstToItsLastMoment() async throws {
        // The first one depends on the hidden frames before the clip's start.
        let file = try await clip()
        await file.assertDecodes(at: 0)
        await file.assertDecodes(at: Self.seconds - 0.1)
    }

    // MARK: - Audio tracks

    func testTheFirstAudioTrackIsTheMixAndTheSourcesFollowDisabled() async throws {
        let file = try await clip()
        let enabled = try await file.audioEnabled()
        XCTAssertEqual(enabled, [true, false, false])
        let info = await file.info()
        XCTAssertEqual(info?.audio, [.mix, .system, .microphone])
    }

    func testTheMixHoldsBothTones() async throws {
        let file = try await clip()
        let system = try await file.level(of: Synthetic.systemTone, inAudioTrack: 0)
        let microphone = try await file.level(of: Synthetic.microphoneTone, inAudioTrack: 0)
        XCTAssertEqual(system, Synthetic.toneLevel, accuracy: 1)
        XCTAssertEqual(microphone, Synthetic.toneLevel, accuracy: 1)
    }

    func testTheSystemTrackHoldsOnlyTheSystemTone() async throws {
        let file = try await clip()
        let system = try await file.level(of: Synthetic.systemTone, inAudioTrack: 1)
        let microphone = try await file.level(of: Synthetic.microphoneTone, inAudioTrack: 1)
        XCTAssertEqual(system, Synthetic.toneLevel, accuracy: 1)
        XCTAssertLessThan(microphone, Synthetic.toneLevel - 40)
    }

    func testTheMicrophoneTrackHoldsOnlyTheMicrophoneTone() async throws {
        let file = try await clip()
        let system = try await file.level(of: Synthetic.systemTone, inAudioTrack: 2)
        let microphone = try await file.level(of: Synthetic.microphoneTone, inAudioTrack: 2)
        XCTAssertLessThan(system, Synthetic.toneLevel - 40)
        XCTAssertEqual(microphone, Synthetic.toneLevel, accuracy: 1)
    }

    func testWithoutTheMicrophoneThereIsOneOrdinaryTrack() async throws {
        let file = MediaFile(try await Synthetic.makeClip(in: directory, seconds: 3, microphone: false))
        let enabled = try await file.audioEnabled()
        XCTAssertEqual(enabled, [true])
        let info = await file.info()
        XCTAssertEqual(info?.audio, [.system])
        let system = try await file.level(of: Synthetic.systemTone, inAudioTrack: 0)
        let microphone = try await file.level(of: Synthetic.microphoneTone, inAudioTrack: 0)
        XCTAssertEqual(system, Synthetic.toneLevel, accuracy: 1)
        XCTAssertLessThan(microphone, Synthetic.toneLevel - 40)
    }

    func testWithoutSeparateTracksOnlyTheMixIsWritten() async throws {
        let file = MediaFile(try await Synthetic.makeClip(in: directory, seconds: 3, keepStems: false))
        let enabled = try await file.audioEnabled()
        XCTAssertEqual(enabled, [true])
        let info = await file.info()
        XCTAssertEqual(info?.audio, [.mix])
        let system = try await file.level(of: Synthetic.systemTone, inAudioTrack: 0)
        let microphone = try await file.level(of: Synthetic.microphoneTone, inAudioTrack: 0)
        XCTAssertEqual(system, Synthetic.toneLevel, accuracy: 1)
        XCTAssertEqual(microphone, Synthetic.toneLevel, accuracy: 1)
    }

    // MARK: - Metadata and files

    func testTheClipCarriesItsGameAndTime() async throws {
        let recorded = Date(timeIntervalSince1970: 1_792_000_000)
        let written = ClipInfo(game: "Rocket League", bundleID: "com.psyonix.rocketleague", recorded: recorded)
        let file = MediaFile(try await Synthetic.makeClip(in: directory, seconds: 3, info: written))
        let read = await file.info()
        let info = try XCTUnwrap(read)
        XCTAssertEqual(info.game, "Rocket League")
        XCTAssertEqual(info.bundleID, "com.psyonix.rocketleague")
        XCTAssertEqual(info.recorded, recorded)
        XCTAssertNil(info.levels)
    }

    func testASecondClipWithTheSameNameGetsANumber() async throws {
        let first = try await Synthetic.makeClip(in: directory, name: "Chess_2026-10-14_04-50-32", seconds: 2)
        let second = try await Synthetic.makeClip(in: directory, name: "Chess_2026-10-14_04-50-32", seconds: 2)
        XCTAssertEqual(first.lastPathComponent, "Chess_2026-10-14_04-50-32.mp4")
        XCTAssertEqual(second.lastPathComponent, "Chess_2026-10-14_04-50-32_2.mp4")
        XCTAssertEqual(ClipCatalog.list(directory).count, 2)
        // AVAssetWriter leaves its working copy ("<name>.mp4.sb-…") next to the
        // file for a moment after it reports completion; it has to go away.
        for _ in 0..<50 where tree().count > 2 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(tree(), ["Chess_2026-10-14_04-50-32.mp4", "Chess_2026-10-14_04-50-32_2.mp4"])
    }

    func testTheGameFolderIsCreatedOnDemand() async throws {
        let folder = ClipCatalog.gameDirectory("Rocket League", in: directory)
        let url = try await Synthetic.makeClip(in: folder, name: ClipNaming.clipName(game: "Rocket League"), seconds: 2)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Rocket League")
        let listed = ClipCatalog.list(directory)
        XCTAssertEqual(listed.map(\.category), [.game("Rocket League")])
    }

    func testAnUnwritableFolderIsReportedAsSuch() async throws {
        // A file where the folder should be.
        let blocked = try touch("not-a-folder")
        do {
            _ = try await Synthetic.makeClip(in: blocked, seconds: 2)
            XCTFail("Writing into a file should fail")
        } catch ClipWriter.WriteError.directoryUnavailable(let path) {
            XCTAssertEqual(path, blocked.path)
        }
    }
}
