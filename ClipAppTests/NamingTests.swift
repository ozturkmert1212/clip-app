import XCTest

final class NamingTests: TemporaryDirectoryTestCase {
    /// 2026-10-14 04:50:32 in the current time zone, which is what names use.
    private let date: Date = {
        var components = DateComponents()
        (components.year, components.month, components.day) = (2026, 10, 14)
        (components.hour, components.minute, components.second) = (4, 50, 32)
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    // MARK: - Cleaning a game name

    func testSeparatorsAndControlCharactersBecomeSpaces() {
        XCTAssertEqual(GameContext.folderName("Half/Life: Alyx\\ 2"), "Half Life Alyx 2")
        XCTAssertEqual(GameContext.folderName("Line\nBreak\tTab"), "Line Break Tab")
    }

    func testSpacesAreCollapsedAndEdgesTrimmed() {
        XCTAssertEqual(GameContext.folderName("  Rocket   League  "), "Rocket League")
        XCTAssertEqual(GameContext.folderName("...hidden."), "hidden")
    }

    func testOrdinaryNamesAreKept() {
        XCTAssertEqual(GameContext.folderName("Rocket League"), "Rocket League")
        XCTAssertEqual(GameContext.folderName("Çılgın Oyun 2 (Beta)"), "Çılgın Oyun 2 (Beta)")
    }

    func testANameWithNothingLeftBecomesDesktop() {
        XCTAssertEqual(GameContext.folderName(""), GameContext.desktop)
        XCTAssertEqual(GameContext.folderName(" /:. "), GameContext.desktop)
    }

    // MARK: - File names

    func testClipAndRecordingNames() {
        XCTAssertEqual(ClipNaming.clipName(game: "Rocket League", date: date), "Rocket League_2026-10-14_04-50-32")
        XCTAssertEqual(ClipNaming.clipName(game: GameContext.desktop, date: date), "Desktop_2026-10-14_04-50-32")
        XCTAssertEqual(ClipNaming.recordingName(date: date), "Recording_2026-10-14_04-50-32")
    }

    func testALongGameNameIsCutInTheFileName() {
        let game = String(repeating: "Very Long Game Title ", count: 8).trimmingCharacters(in: .whitespaces)
        let name = ClipNaming.clipName(game: game, date: date)
        XCTAssertLessThanOrEqual(name.count, ClipNaming.maximumGameLength + "_2026-10-14_04-50-32".count)
        XCTAssertTrue(name.hasSuffix("_2026-10-14_04-50-32"))
        XCTAssertTrue(game.hasPrefix(String(name.dropLast("_2026-10-14_04-50-32".count))))
        XCTAssertFalse(name.contains(" _"), "no space left before the date")
    }

    // MARK: - Renaming on a move

    func testAnAutomaticNameFollowsTheGame() {
        XCTAssertEqual(
            ClipNaming.renamed("Chess_2026-10-14_04-50-32", from: "Chess", to: "Rocket League"),
            "Rocket League_2026-10-14_04-50-32"
        )
    }

    func testAClashSuffixIsDroppedAndAnEditSuffixKept() {
        XCTAssertEqual(
            ClipNaming.renamed("Chess_2026-10-14_04-50-32_2", from: "Chess", to: "Go"), "Go_2026-10-14_04-50-32"
        )
        XCTAssertEqual(
            ClipNaming.renamed("Chess_2026-10-14_04-50-32 (trimmed)", from: "Chess", to: "Go"),
            "Go_2026-10-14_04-50-32 (trimmed)"
        )
        XCTAssertEqual(
            ClipNaming.renamed("Chess_2026-10-14_04-50-32_3 (edited 2)", from: "Chess", to: "Go"),
            "Go_2026-10-14_04-50-32 (edited 2)"
        )
    }

    func testNamesTheUserGaveAreLeftAlone() {
        XCTAssertNil(ClipNaming.renamed("my best goal", from: "Chess", to: "Go"))
        XCTAssertNil(ClipNaming.renamed("Chess_2026-10-14_04-50-32 final", from: "Chess", to: "Go"))
        XCTAssertNil(ClipNaming.renamed("Chess_goal", from: "Chess", to: "Go"))
    }

    func testOldStyleAndForeignNamesAreLeftAlone() {
        XCTAssertNil(ClipNaming.renamed("Clip_2026-10-11_18-38-58", from: "Chess", to: "Go"))
        XCTAssertNil(ClipNaming.renamed("Safari_2026-10-14_04-50-32", from: "Chess", to: "Go"))
    }

    func testGameNamesWithPatternCharactersAndLongNames() {
        XCTAssertEqual(
            ClipNaming.renamed("C++ (Beta) [x]_2026-10-14_04-50-32", from: "C++ (Beta) [x]", to: "Go"),
            "Go_2026-10-14_04-50-32"
        )
        let long = String(repeating: "Very Long Game Title ", count: 8).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(
            ClipNaming.renamed(ClipNaming.clipName(game: long, date: date), from: long, to: "Go"),
            "Go_2026-10-14_04-50-32"
        )
    }

    // MARK: - Name clashes

    func testAFreeNameIsUsedAsItIs() {
        let url = ClipNaming.uniqueURL(in: directory, name: "Chess_2026-10-14_04-50-32")
        XCTAssertEqual(url.lastPathComponent, "Chess_2026-10-14_04-50-32.mp4")
    }

    func testATakenNameGetsTheNextFreeNumber() throws {
        try touch("clip.mp4")
        XCTAssertEqual(ClipNaming.uniqueURL(in: directory, name: "clip").lastPathComponent, "clip_2.mp4")
        try touch("clip_2.mp4")
        try touch("clip_3.mp4")
        XCTAssertEqual(ClipNaming.uniqueURL(in: directory, name: "clip").lastPathComponent, "clip_4.mp4")
        // A gap is filled: the first free number wins.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("clip_2.mp4"))
        XCTAssertEqual(ClipNaming.uniqueURL(in: directory, name: "clip").lastPathComponent, "clip_2.mp4")
    }

    func testOtherExtensionsDoNotClash() throws {
        try touch("clip.mov")
        XCTAssertEqual(ClipNaming.uniqueURL(in: directory, name: "clip").lastPathComponent, "clip.mp4")
        XCTAssertEqual(ClipNaming.uniqueURL(in: directory, name: "clip", pathExtension: "mov").lastPathComponent, "clip_2.mov")
    }
}
