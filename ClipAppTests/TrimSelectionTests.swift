import CoreMedia
import XCTest

final class TrimSelectionTests: XCTestCase {
    func testStartsAsTheWholeClip() {
        let selection = TrimSelection(duration: 30)
        XCTAssertEqual(selection.start, 0)
        XCTAssertEqual(selection.end, 30)
        XCTAssertFalse(selection.isTrimmed)
        XCTAssertEqual(selection.range.duration.seconds, 30, accuracy: 0.001)
    }

    func testHandlesGiveTheRangeBetweenThem() {
        var selection = TrimSelection(duration: 30)
        selection.setStart(5.3)
        selection.setEnd(12.7)
        XCTAssertTrue(selection.isTrimmed)
        XCTAssertEqual(selection.length, 7.4, accuracy: 0.0001)
        XCTAssertEqual(selection.range.start.seconds, 5.3, accuracy: 0.002)
        XCTAssertEqual(selection.range.end.seconds, 12.7, accuracy: 0.002)
    }

    func testHandlesStayInsideTheClip() {
        var selection = TrimSelection(duration: 10)
        selection.setStart(-4)
        XCTAssertEqual(selection.start, 0)
        selection.setEnd(99)
        XCTAssertEqual(selection.end, 10)
    }

    func testHandlesCannotCrossOrComeCloserThanTheMinimum() {
        var selection = TrimSelection(duration: 10)
        selection.setEnd(6)
        selection.setStart(9)
        XCTAssertEqual(selection.start, 6 - TrimSelection.minimumLength, accuracy: 0.0001)
        selection.setEnd(1)
        XCTAssertEqual(selection.end, selection.start + TrimSelection.minimumLength, accuracy: 0.0001)
        XCTAssertEqual(selection.length, TrimSelection.minimumLength, accuracy: 0.0001)
    }

    func testTinyOffsetsDoNotCountAsTrimmed() {
        var selection = TrimSelection(duration: 10)
        selection.setStart(0.005)
        XCTAssertFalse(selection.isTrimmed)
        selection.setEnd(9.5)
        XCTAssertTrue(selection.isTrimmed)
    }

    func testAnEmptyClipIsNeverTrimmed() {
        XCTAssertFalse(TrimSelection(duration: 0).isTrimmed)
    }
}
