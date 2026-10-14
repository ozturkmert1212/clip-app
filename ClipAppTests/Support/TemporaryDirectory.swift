import Foundation
import XCTest

/// A test case with a scratch folder of its own that is removed afterwards.
class TemporaryDirectoryTestCase: XCTestCase {
    private(set) var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// An empty file at `path` under the scratch folder, with its folders.
    @discardableResult
    func touch(_ path: String) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        return url
    }

    /// Every file under the scratch folder, as sorted relative paths.
    func tree() -> [String] {
        let base = directory.resolvingSymlinksInPath().path + "/"
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        var paths: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            paths.append(url.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: ""))
        }
        return paths.sorted()
    }
}
