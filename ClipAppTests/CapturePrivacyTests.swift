import XCTest

final class CapturePrivacyTests: XCTestCase {
    private let own = "com.mertozturk.ClipApp"
    private let notificationCenter = CapturePrivacy.notificationCenterBundleIdentifier

    private func privacy(showing: Bool) -> CapturePrivacy {
        CapturePrivacy(showsClipApp: showing, ownBundleIdentifier: own)
    }

    // MARK: - Stored setting

    func testHiddenWithoutAStoredValue() throws {
        let suite = "ClipAppTests.CapturePrivacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(CapturePrivacy.showsClipAppDefault)
        XCTAssertFalse(CapturePrivacy.storedShowsClipApp(in: defaults))
        defaults.set(true, forKey: CapturePrivacy.showsClipAppKey)
        XCTAssertTrue(CapturePrivacy.storedShowsClipApp(in: defaults))
        defaults.set(false, forKey: CapturePrivacy.showsClipAppKey)
        XCTAssertFalse(CapturePrivacy.storedShowsClipApp(in: defaults))
    }

    func testAStoredValueOfTheWrongTypeCountsAsNone() throws {
        let suite = "ClipAppTests.CapturePrivacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("yes", forKey: CapturePrivacy.showsClipAppKey)
        XCTAssertFalse(CapturePrivacy.storedShowsClipApp(in: defaults))
    }

    // MARK: - Filter

    func testHiddenExcludesClipAppAndNotificationCenter() {
        let hidden = privacy(showing: false)
        XCTAssertEqual(Set(hidden.excludedApplications), [own, notificationCenter])
        // The application exclusion already covers the HUD.
        XCTAssertFalse(hidden.excludesHiddenWindowsByID(ownApplicationFound: true))
        XCTAssertFalse(hidden.ordinaryWindowsShareable)
    }

    func testHiddenFallsBackToWindowIDsWhenClipAppIsNotFound() {
        XCTAssertTrue(privacy(showing: false).excludesHiddenWindowsByID(ownApplicationFound: false))
    }

    func testShownExcludesOnlyNotificationCenterAndTheHUDByID() {
        let shown = privacy(showing: true)
        XCTAssertEqual(shown.excludedApplications, [notificationCenter])
        XCTAssertTrue(shown.excludesHiddenWindowsByID(ownApplicationFound: true))
        XCTAssertTrue(shown.excludesHiddenWindowsByID(ownApplicationFound: false))
        XCTAssertTrue(shown.ordinaryWindowsShareable)
    }

    // MARK: - Sources

    func testClipAppIsNeverASourceEitherWay() {
        for showing in [false, true] {
            let privacy = privacy(showing: showing)
            XCTAssertFalse(privacy.canBeSource(bundleIdentifier: own))
            XCTAssertTrue(privacy.canBeSource(bundleIdentifier: "com.apple.Chess"))
            // A window whose owner is unknown is not ours.
            XCTAssertTrue(privacy.canBeSource(bundleIdentifier: nil))
        }
    }
}
