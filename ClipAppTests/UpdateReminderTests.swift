import XCTest

/// Where an update found by a scheduled check shows up (`UpdateReminder`).
final class UpdateReminderTests: XCTestCase {
    /// The user is looking at ClipApp's window right after launch, nothing runs.
    private let lookingAtTheWindow = UpdateReminder.Situation(
        checksAutomatically: true, appIsActive: true, mainWindowVisible: true,
        immediateFocus: true, isCapturing: false, notificationsAllowed: true
    )

    /// ClipApp is in the background, its window closed: the user is in a game.
    private let inTheBackground = UpdateReminder.Situation(
        checksAutomatically: true, appIsActive: false, mainWindowVisible: false,
        immediateFocus: false, isCapturing: false, notificationsAllowed: true
    )

    func testSparkleShowsTheUpdateWhileTheUserLooksAtTheWindow() {
        XCTAssertEqual(UpdateReminder.presentation(in: lookingAtTheWindow), .sparkleWindow)
        XCTAssertEqual(UpdateReminder.surfaces(for: "0.4.0", in: lookingAtTheWindow, notifiedVersion: nil), [])
    }

    func testInTheBackgroundTheAppRemindsInEveryPlace() {
        XCTAssertEqual(UpdateReminder.presentation(in: inTheBackground), .reminder)
        XCTAssertEqual(
            UpdateReminder.surfaces(for: "0.4.0", in: inTheBackground, notifiedVersion: nil),
            [.menu, .sidebar, .notification]
        )
    }

    func testAnyReasonNotToInterruptGivesAReminder() {
        var situations: [UpdateReminder.Situation] = []
        var inactive = lookingAtTheWindow
        inactive.appIsActive = false
        situations.append(inactive)
        var windowClosed = lookingAtTheWindow
        windowClosed.mainWindowVisible = false
        situations.append(windowClosed)
        var notInFocus = lookingAtTheWindow
        notInFocus.immediateFocus = false
        situations.append(notInFocus)
        var capturing = lookingAtTheWindow
        capturing.isCapturing = true
        situations.append(capturing)
        for situation in situations {
            XCTAssertEqual(UpdateReminder.presentation(in: situation), .reminder, "\(situation)")
            XCTAssertTrue(UpdateReminder.surfaces(for: "0.4.0", in: situation, notifiedVersion: nil).isSuperset(of: [.menu, .sidebar]))
        }
    }

    func testTheSameVersionIsNotifiedOnlyOnce() {
        XCTAssertEqual(
            UpdateReminder.surfaces(for: "0.4.0", in: inTheBackground, notifiedVersion: "0.4.0"),
            [.menu, .sidebar]
        )
        // A newer version gets its own notification.
        XCTAssertTrue(UpdateReminder.surfaces(for: "0.4.1", in: inTheBackground, notifiedVersion: "0.4.0").contains(.notification))
    }

    func testNoNotificationWithoutPermissionOrWhileActive() {
        var noPermission = inTheBackground
        noPermission.notificationsAllowed = false
        XCTAssertEqual(UpdateReminder.surfaces(for: "0.4.0", in: noPermission, notifiedVersion: nil), [.menu, .sidebar])

        // In front, but recording: the menu and the window remind, no banner.
        var activeAndRecording = lookingAtTheWindow
        activeAndRecording.isCapturing = true
        XCTAssertEqual(UpdateReminder.surfaces(for: "0.4.0", in: activeAndRecording, notifiedVersion: nil), [.menu, .sidebar])
    }

    func testNothingAtAllWithAutomaticChecksOff() {
        for var situation in [lookingAtTheWindow, inTheBackground] {
            situation.checksAutomatically = false
            XCTAssertEqual(UpdateReminder.presentation(in: situation), .nothing)
            XCTAssertEqual(UpdateReminder.surfaces(for: "0.4.0", in: situation, notifiedVersion: nil), [])
        }
    }
}
