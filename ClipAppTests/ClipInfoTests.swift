import AVFoundation
import XCTest

final class ClipInfoTests: XCTestCase {
    private let recorded = Date(timeIntervalSince1970: 1_792_000_000)

    func testEverythingSurvivesTheRoundTrip() throws {
        let info = ClipInfo(
            game: "Rocket League", bundleID: "com.psyonix.rocketleague", recorded: recorded,
            audio: [.mix, .system, .microphone], levels: ["system": 0.5, "microphone": 0]
        )
        let json = try XCTUnwrap(info.json)
        XCTAssertEqual(ClipInfo(json: json), info)
    }

    func testOptionalFieldsMayBeAbsent() throws {
        let info = ClipInfo(game: GameContext.desktop, bundleID: nil, recorded: recorded)
        let back = try XCTUnwrap(ClipInfo(json: try XCTUnwrap(info.json)))
        XCTAssertEqual(back.game, "Desktop")
        XCTAssertNil(back.bundleID)
        XCTAssertNil(back.audio)
        XCTAssertNil(back.levels)
    }

    func testTheStoredFormIsReadableAndStable() throws {
        let info = ClipInfo(game: "Chess", bundleID: "com.apple.Chess", recorded: recorded, audio: [.mix, .system, .microphone])
        XCTAssertEqual(
            info.json,
            #"{"audio":["mix","system","microphone"],"bundleID":"com.apple.Chess","game":"Chess","recorded":"2026-10-14T17:46:40Z"}"#
        )
    }

    func testARecordWrittenByAnOlderVersionStillReads() throws {
        // Before track roles and levels existed.
        let info = try XCTUnwrap(ClipInfo(json: #"{"bundleID":"com.apple.Chess","game":"Chess","recorded":"2026-10-14T01:11:29Z"}"#))
        XCTAssertEqual(info.game, "Chess")
        XCTAssertNil(info.audio)
    }

    func testOtherCommentsAreNotMistakenForARecord() {
        XCTAssertNil(ClipInfo(json: "Recorded with some other app"))
        XCTAssertNil(ClipInfo(json: "{}"))
        XCTAssertNil(ClipInfo(json: #"{"game":"Chess"}"#))
        XCTAssertNil(ClipInfo(json: #"{"game":"Chess","recorded":"yesterday"}"#))
        XCTAssertNil(ClipInfo(json: #"{"game":"Chess","recorded":"2026-10-14T01:11:29Z","audio":["surround"]}"#))
    }

    func testTheMetadataItemIsTheCommentHoldingTheRecord() throws {
        let info = ClipInfo(game: "Chess", bundleID: nil, recorded: recorded)
        let items = info.metadataItems
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.identifier, .iTunesMetadataUserComment)
        XCTAssertEqual(item.value as? String, info.json)
    }
}
