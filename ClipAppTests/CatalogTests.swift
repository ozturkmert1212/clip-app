import XCTest

final class CatalogTests: TemporaryDirectoryTestCase {
    private func item(_ path: String, _ category: ClipItem.Category) -> ClipItem {
        ClipItem(url: directory.appendingPathComponent(path), category: category, date: Date(), size: 0, fingerprint: path)
    }

    // MARK: - Layout

    func testClipsGoUnderClipsByGameAndRecordingsUnderVideos() {
        let root = URL(fileURLWithPath: "/Movies/ClipApp", isDirectory: true)
        XCTAssertEqual(ClipCatalog.clipsDirectory(in: root).path, "/Movies/ClipApp/Clips")
        XCTAssertEqual(ClipCatalog.videosDirectory(in: root).path, "/Movies/ClipApp/Videos")
        XCTAssertEqual(ClipCatalog.gameDirectory("Rocket League", in: root).path, "/Movies/ClipApp/Clips/Rocket League")
        XCTAssertEqual(ClipCatalog.gameDirectory("Half/Life: Alyx", in: root).path, "/Movies/ClipApp/Clips/Half Life Alyx")
        XCTAssertEqual(ClipCatalog.gameDirectory("", in: root).path, "/Movies/ClipApp/Clips/Desktop")
    }

    // MARK: - Listing

    func testFilesAreSortedIntoGamesOtherAndVideos() throws {
        try touch("Clips/Rocket League/a.mp4")
        try touch("Clips/Rocket League/b.MP4")
        try touch("Clips/Chess/c.mp4")
        try touch("Clips/loose.mp4")
        try touch("Clip_2026-10-11_18-38-58.mp4")
        try touch("Videos/Recording_2026-10-14_05-00-07.mp4")
        let categories = Dictionary(grouping: ClipCatalog.list(directory), by: \.category).mapValues { $0.map(\.name).sorted() }
        XCTAssertEqual(categories[.game("Rocket League")], ["a", "b"])
        XCTAssertEqual(categories[.game("Chess")], ["c"])
        XCTAssertEqual(categories[.other], ["Clip_2026-10-11_18-38-58", "loose"])
        XCTAssertEqual(categories[.video], ["Recording_2026-10-14_05-00-07"])
        XCTAssertEqual(categories.count, 4)
    }

    func testOnlyVisibleMP4FilesAreListed() throws {
        try touch("Clips/Chess/clip.mp4")
        try touch("Clips/Chess/notes.txt")
        try touch("Clips/Chess/.hidden.tmp.mp4")
        try touch("Clips/Chess/Deeper/too-deep.mp4")
        try touch("Videos/Sub/not-listed.mp4")
        try touch("Elsewhere/not-listed.mp4")
        XCTAssertEqual(ClipCatalog.list(directory).map(\.name), ["clip"])
    }

    func testNewestComesFirst() throws {
        let old = try touch("Clips/Chess/old.mp4")
        let new = try touch("Videos/new.mp4")
        let middle = try touch("middle.mp4")
        let now = Date()
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-300)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-200)], ofItemAtPath: middle.path)
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-100)], ofItemAtPath: new.path)
        XCTAssertEqual(ClipCatalog.list(directory).map(\.name), ["new", "middle", "old"])
    }

    func testAMissingFolderListsNothing() {
        XCTAssertTrue(ClipCatalog.list(directory.appendingPathComponent("nope")).isEmpty)
    }

    func testTheFingerprintChangesWithTheFile() throws {
        let url = try touch("Clips/Chess/clip.mp4")
        let before = try XCTUnwrap(ClipCatalog.list(directory).first).fingerprint
        try Data(repeating: 1, count: 100).write(to: url)
        XCTAssertNotEqual(try XCTUnwrap(ClipCatalog.list(directory).first).fingerprint, before)
    }

    // MARK: - Moving to another game

    func testAMoveRenamesAutomaticNamesAndKeepsTheUsers() throws {
        try touch("Clips/Chess/Chess_2026-10-14_04-59-56.mp4")
        try touch("Clips/Chess/my best goal.mp4")
        try touch("Clip_2026-10-11_18-38-58.mp4")
        try ClipCatalog.move(ClipCatalog.list(directory), toGame: "Rocket League: 2026/Edition", root: directory)
        XCTAssertEqual(tree(), [
            "Clips/Rocket League 2026 Edition/Clip_2026-10-11_18-38-58.mp4",
            "Clips/Rocket League 2026 Edition/Rocket League 2026 Edition_2026-10-14_04-59-56.mp4",
            "Clips/Rocket League 2026 Edition/my best goal.mp4",
        ])
    }

    func testAMoveResolvesNameClashes() throws {
        try touch("Clips/Go/Go_2026-10-14_04-59-56.mp4")
        try touch("Clips/Go/goal.mp4")
        try touch("Clips/Chess/Chess_2026-10-14_04-59-56.mp4")
        try touch("Clips/Chess/goal.mp4")
        let chess = ClipCatalog.list(directory).filter { $0.category == .game("Chess") }
        let moved = try ClipCatalog.move(chess, toGame: "Go", root: directory)
        XCTAssertEqual(Set(moved.map(\.lastPathComponent)), ["Go_2026-10-14_04-59-56_2.mp4", "goal_2.mp4"])
        XCTAssertEqual(tree().filter { $0.hasPrefix("Clips/Go/") }.count, 4)
    }

    func testRecordingsAndClipsAlreadyThereStayPut() throws {
        try touch("Videos/Recording_2026-10-14_05-00-07.mp4")
        try touch("Clips/Go/Go_2026-10-14_04-59-56.mp4")
        let before = tree()
        let moved = try ClipCatalog.move(ClipCatalog.list(directory), toGame: "Go", root: directory)
        XCTAssertTrue(moved.isEmpty)
        XCTAssertEqual(tree(), before)
    }

    func testAMoveToANewGameCreatesItsFolder() throws {
        try touch("Clips/Chess/Chess_2026-10-14_04-59-56.mp4")
        try ClipCatalog.move([item("Clips/Chess/Chess_2026-10-14_04-59-56.mp4", .game("Chess"))], toGame: "Brand New", root: directory)
        XCTAssertEqual(tree(), ["Clips/Brand New/Brand New_2026-10-14_04-59-56.mp4"])
        XCTAssertEqual(ClipCatalog.list(directory).map(\.category), [.game("Brand New")])
    }

    func testAMissingFileStopsTheMoveWithAnError() throws {
        try touch("Clips/Chess/there.mp4")
        let clips = [item("Clips/Chess/gone.mp4", .game("Chess")), item("Clips/Chess/there.mp4", .game("Chess"))]
        XCTAssertThrowsError(try ClipCatalog.move(clips, toGame: "Go", root: directory))
        XCTAssertEqual(tree(), ["Clips/Chess/there.mp4"])
    }
}
