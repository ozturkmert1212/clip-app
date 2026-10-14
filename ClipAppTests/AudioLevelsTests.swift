import XCTest

final class AudioLevelsTests: XCTestCase {
    func testUntouchedControlsRenderAsRecorded() {
        XCTAssertEqual(AudioLevels().edit, ClipTrimmer.AudioEdit(system: 1, microphone: 1))
        XCTAssertEqual(AudioLevels().edit, ClipTrimmer.AudioEdit())
    }

    func testSlidersAreTheGains() {
        var levels = AudioLevels()
        levels.system = 0.5
        levels.microphone = AudioLevels.maximum
        XCTAssertEqual(levels.edit, ClipTrimmer.AudioEdit(system: 0.5, microphone: 1.5))
    }

    func testMuteSilencesWhateverTheSliderSays() {
        var levels = AudioLevels()
        levels.system = 1.2
        levels.systemMuted = true
        XCTAssertEqual(levels.edit.system, 0)
        XCTAssertEqual(levels.edit.microphone, 1)
        levels.systemMuted = false
        XCTAssertEqual(levels.edit.system, 1.2)
    }

    func testSavedLevelsComeBackAsTheControls() {
        let levels = AudioLevels(saved: ClipTrimmer.AudioEdit(system: 0.5, microphone: 1.5))
        XCTAssertEqual(levels.system, 0.5)
        XCTAssertEqual(levels.microphone, 1.5)
        XCTAssertFalse(levels.systemMuted)
        XCTAssertFalse(levels.microphoneMuted)
    }

    func testASavedZeroComesBackAsMutedAtFullLevel() {
        let levels = AudioLevels(saved: ClipTrimmer.AudioEdit(system: 0.5, microphone: 0))
        XCTAssertTrue(levels.microphoneMuted)
        XCTAssertEqual(levels.microphone, 1)
        // Rendering it again gives the same mix as before.
        XCTAssertEqual(levels.edit, ClipTrimmer.AudioEdit(system: 0.5, microphone: 0))
    }

    func testControlsAndSavedLevelsRoundTrip() {
        for edit in [
            ClipTrimmer.AudioEdit(), ClipTrimmer.AudioEdit(system: 0, microphone: 0),
            ClipTrimmer.AudioEdit(system: 1.5, microphone: 0.05), ClipTrimmer.AudioEdit(system: 0, microphone: 1.5),
        ] {
            XCTAssertEqual(AudioLevels(saved: edit).edit, edit)
        }
    }

    func testStoredLevelsAreKeyedByRole() {
        let edit = ClipTrimmer.AudioEdit(system: 0.5, microphone: 0)
        XCTAssertEqual(edit.stored, ["system": 0.5, "microphone": 0])
        XCTAssertEqual(ClipTrimmer.AudioEdit(stored: edit.stored), edit)
    }

    func testMissingStoredLevelsMeanAsRecorded() {
        XCTAssertEqual(ClipTrimmer.AudioEdit(stored: nil), ClipTrimmer.AudioEdit())
        XCTAssertEqual(ClipTrimmer.AudioEdit(stored: ["microphone": 0.25]), ClipTrimmer.AudioEdit(system: 1, microphone: 0.25))
    }
}
