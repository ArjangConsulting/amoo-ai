@testable import AmooCore
import Foundation
import TestCommons
import XCTest

final class AppArtifactPathTests: XCTestCase {
    private func makeScratch() throws -> TemporaryDirectory {
        let scratch = try TemporaryDirectory()
        addTeardownBlock { try? scratch.remove() }
        return scratch
    }

    private func makeDirectory(_ name: String, in scratch: TemporaryDirectory) throws -> URL {
        let url = scratch.url.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testValidArtifactsReturnTheirPath() throws {
        let scratch = try makeScratch()
        let app = try makeDirectory("Demo.app", in: scratch)
        let apk = try scratch.write(Data("apk".utf8), named: "demo.apk")

        XCTAssertEqual(try AppArtifactPath.validated(app.path, platform: .ios), app.standardizedFileURL.path)
        XCTAssertEqual(try AppArtifactPath.validated(apk.path, platform: .android), apk.standardizedFileURL.path)
        XCTAssertEqual(try AppArtifactPath.validated(" \(app.path)\n", platform: nil), app.standardizedFileURL.path)
    }

    /// The reported friction: a one-letter typo surfaced only as an lstat error from simctl.
    func testTypoNamesThePathAndSuggestsTheSibling() throws {
        let scratch = try makeScratch()
        let app = try makeDirectory("TaskList.app", in: scratch)
        _ = try makeDirectory("TaskList.app.dSYM", in: scratch)
        let typo = scratch.url.appending(path: "TaskLsit.app").path

        XCTAssertThrowsError(try AppArtifactPath.validated(typo, platform: .ios)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("No app artifact at \(typo)"), message)
            XCTAssertTrue(message.contains("Did you mean: \(app.path)?"), message)
            XCTAssertFalse(message.contains("dSYM"), message)
        }
    }

    func testMissingParentReportsDeepestExistingDirectory() throws {
        let scratch = try makeScratch()
        let path = scratch.url.appending(path: "Debug-iphonesimulatr/Demo.app").path

        let expected = "Deepest existing directory: \(scratch.url.standardizedFileURL.path)"
        XCTAssertThrowsError(try AppArtifactPath.validated(path, platform: .ios)) { error in
            XCTAssertTrue(String(describing: error).contains(expected), String(describing: error))
        }
    }

    func testWrongArtifactShapeForPlatformIsRejected() throws {
        let scratch = try makeScratch()
        let app = try makeDirectory("Demo.app", in: scratch)
        let apk = try scratch.write(Data("apk".utf8), named: "demo.apk")
        let dsym = try makeDirectory("Demo.app.dSYM", in: scratch)

        XCTAssertThrowsError(try AppArtifactPath.validated(app.path, platform: .android))
        XCTAssertThrowsError(try AppArtifactPath.validated(apk.path, platform: .ios))
        XCTAssertThrowsError(try AppArtifactPath.validated(dsym.path, platform: .ios))
        XCTAssertThrowsError(try AppArtifactPath.validated("  ", platform: nil))
    }

    func testEditDistance() {
        XCTAssertEqual(AppArtifactPath.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(AppArtifactPath.editDistance("", "abc"), 3)
        XCTAssertEqual(AppArtifactPath.editDistance("same", "same"), 0)
    }
}
