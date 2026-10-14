import XCTest

final class GameMemoryTests: XCTestCase {
    private let own = "com.mertozturk.ClipApp"
    private let clipApp = FrontApp(name: "ClipApp", bundleID: "com.mertozturk.ClipApp")
    private let finder = FrontApp(name: "Finder", bundleID: "com.apple.finder")
    private let dock = FrontApp(name: "Dock", bundleID: "com.apple.dock")
    private let game = FrontApp(name: "Rocket League", bundleID: "com.psyonix.rocketleague")
    private let other = FrontApp(name: "Chess", bundleID: "com.apple.Chess")
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private let desktop = GameContext(name: GameContext.desktop, bundleID: nil)
    private let rocketLeague = GameContext(name: "Rocket League", bundleID: "com.psyonix.rocketleague")

    // MARK: - What counts as a game

    func testAnOrdinaryAppInFrontIsTheGame() {
        let memory = GameMemory(ownBundleID: own)
        XCTAssertEqual(memory.current(front: game, within: 30, now: start), rocketLeague)
    }

    func testClipAppFinderDockAndSystemUIAreNeverTheGame() {
        let memory = GameMemory(ownBundleID: own)
        XCTAssertNil(memory.context(for: clipApp))
        XCTAssertNil(memory.context(for: finder))
        XCTAssertNil(memory.context(for: dock))
        for bundleID in GameMemory.ignored {
            XCTAssertNil(memory.context(for: FrontApp(name: "System", bundleID: bundleID)), bundleID)
        }
        XCTAssertEqual(memory.current(front: finder, within: 30, now: start), desktop)
        XCTAssertEqual(memory.current(front: clipApp, within: 30, now: start), desktop)
    }

    func testAnAppWithoutNameOrIdentifierIsNotAGame() {
        let memory = GameMemory(ownBundleID: own)
        XCTAssertNil(memory.context(for: nil))
        XCTAssertNil(memory.context(for: FrontApp(name: nil, bundleID: "com.example.game")))
        XCTAssertNil(memory.context(for: FrontApp(name: "Game", bundleID: nil)))
        XCTAssertEqual(memory.current(front: nil, within: 30, now: start), desktop)
    }

    func testTheGameNameIsCleanedForUseAsAFolder() {
        let memory = GameMemory(ownBundleID: own)
        let context = memory.context(for: FrontApp(name: "Half/Life: Alyx", bundleID: "com.valve.alyx"))
        XCTAssertEqual(context, GameContext(name: "Half Life Alyx", bundleID: "com.valve.alyx"))
    }

    // MARK: - Remembering the last game

    func testSavingFromClipAppUsesTheGameThatWasJustLeft() {
        var memory = GameMemory(ownBundleID: own)
        memory.activated(game, at: at(0))
        memory.activated(clipApp, at: at(100))
        XCTAssertEqual(memory.current(front: clipApp, within: 30, now: at(103)), rocketLeague)
    }

    func testTheRememberedGameExpiresWithTheClipWindow() {
        var memory = GameMemory(ownBundleID: own)
        memory.activated(game, at: at(0))
        memory.activated(clipApp, at: at(100))
        XCTAssertEqual(memory.current(front: clipApp, within: 30, now: at(130)), rocketLeague)
        XCTAssertEqual(memory.current(front: clipApp, within: 30, now: at(130.5)), desktop)
        // A longer buffer still reaches it.
        XCTAssertEqual(memory.current(front: clipApp, within: 60, now: at(130.5)), rocketLeague)
    }

    func testFurtherIgnoredAppsDoNotRestartTheClock() {
        var memory = GameMemory(ownBundleID: own)
        memory.activated(game, at: at(0))
        memory.activated(finder, at: at(100))
        memory.activated(clipApp, at: at(120))
        memory.activated(dock, at: at(125))
        XCTAssertEqual(memory.leftFrontAt, at(100))
        XCTAssertEqual(memory.current(front: clipApp, within: 30, now: at(129)), rocketLeague)
        XCTAssertEqual(memory.current(front: clipApp, within: 30, now: at(131)), desktop)
    }

    func testWithoutARememberedGameItIsDesktop() {
        var memory = GameMemory(ownBundleID: own)
        memory.activated(finder, at: at(0))
        memory.activated(clipApp, at: at(1))
        XCTAssertNil(memory.remembered)
        XCTAssertEqual(memory.current(front: clipApp, within: 30, now: at(2)), desktop)
    }

    func testTheAppInFrontWinsOverTheRememberedOne() {
        var memory = GameMemory(ownBundleID: own)
        memory.activated(game, at: at(0))
        memory.activated(clipApp, at: at(10))
        memory.activated(other, at: at(12))
        XCTAssertEqual(memory.current(front: other, within: 30, now: at(13)), GameContext(name: "Chess", bundleID: "com.apple.Chess"))
        // And it is the one remembered from here on.
        memory.activated(clipApp, at: at(20))
        XCTAssertEqual(memory.current(front: clipApp, within: 30, now: at(21)).name, "Chess")
    }

    func testComingBackToTheGameClearsTheClock() {
        var memory = GameMemory(ownBundleID: own)
        memory.activated(game, at: at(0))
        memory.activated(clipApp, at: at(10))
        memory.activated(game, at: at(500))
        XCTAssertNil(memory.leftFrontAt)
        memory.activated(clipApp, at: at(900))
        XCTAssertEqual(memory.current(front: clipApp, within: 30, now: at(905)), rocketLeague)
    }

    func testAGameStillRememberedAsInFrontDoesNotExpire() {
        // An activation that was missed: nothing says the game ever left.
        var memory = GameMemory(ownBundleID: own)
        memory.activated(game, at: at(0))
        XCTAssertEqual(memory.current(front: clipApp, within: 30, now: at(9_999)), rocketLeague)
    }
}
