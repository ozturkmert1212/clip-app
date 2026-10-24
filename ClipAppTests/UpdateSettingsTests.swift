import XCTest

/// The Sparkle keys in the app's Info.plist, which XcodeGen writes from
/// `project.yml`. The tests are not hosted by the app, so the file is read
/// from the source tree.
final class UpdateSettingsTests: XCTestCase {
    private func infoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ClipApp/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testTheFeedIsAnHTTPSURL() throws {
        let feed = try XCTUnwrap(infoPlist()["SUFeedURL"] as? String)
        let url = try XCTUnwrap(URL(string: feed))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertFalse(url.host?.isEmpty ?? true)
        XCTAssertEqual(url.pathExtension, "xml")
    }

    func testThePublicKeyIsAnEd25519Key() throws {
        let key = try XCTUnwrap(infoPlist()["SUPublicEDKey"] as? String)
        XCTAssertFalse(key.isEmpty)
        // An Ed25519 public key is 32 bytes, base64 encoded.
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
    }

    func testUpdatesAreOfferedNotInstalledAndNothingIsProfiled() throws {
        let info = try infoPlist()
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(info["SUScheduledCheckInterval"] as? Int, 86400)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(info["SUEnableSystemProfiling"] as? Bool, false)
    }
}
