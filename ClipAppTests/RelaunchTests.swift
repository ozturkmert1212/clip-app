import XCTest

/// Which copy Restart ClipApp starts (`Relaunch`).
final class RelaunchTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelaunchTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A minimal ClipApp bundle somewhere other than /Applications.
    private func makeCopy(in subfolder: String) throws -> Bundle {
        let app = folder.appendingPathComponent(subfolder, isDirectory: true)
            .appendingPathComponent("ClipApp.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.mertozturk.ClipApp", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: app))
    }

    func testTheRunningCopyIsStartedByItsOwnPath() throws {
        for place in ["build/Build/Products/Release", "Volumes/ClipApp", "AppTranslocation/1234/d"] {
            let copy = try makeCopy(in: place)
            let target = Relaunch.target(for: copy)
            XCTAssertEqual(target.standardizedFileURL, copy.bundleURL.standardizedFileURL, place)
            XCTAssertNotEqual(target.path, "/Applications/ClipApp.app", place)
            XCTAssertTrue(target.path.hasSuffix("\(place)/ClipApp.app"), target.path)
        }
    }

    func testANewInstanceStartsBeforeTheOldOneQuits() {
        XCTAssertTrue(Relaunch.createsNewInstance)
        XCTAssertTrue(Relaunch.quitsAfterLaunch(error: nil))
    }

    func testTheOldInstanceStaysWhenTheNewOneCouldNotStart() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        XCTAssertFalse(Relaunch.quitsAfterLaunch(error: error))
    }
}
