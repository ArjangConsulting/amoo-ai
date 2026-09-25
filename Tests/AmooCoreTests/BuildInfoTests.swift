@testable import AmooCore
import Foundation
import XCTest

final class BuildInfoTests: XCTestCase {
    private func makeBinary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("amoo-bin-\(UUID().uuidString)")
        try Data("v1".utf8).write(to: url)
        return url
    }

    func testFreshBinaryIsNotStale() throws {
        let binary = try makeBinary()
        defer { try? FileManager.default.removeItem(at: binary) }
        let info = AmooBuildInfo.capture(executableURL: binary)
        XCTAssertNil(info.replacedBinaryDate())
        XCTAssertNil(info.stalenessWarning())
    }

    /// Regression: MCP servers started before a fix kept serving old code with no sign of it.
    func testRebuiltBinaryIsReportedStale() throws {
        let binary = try makeBinary()
        defer { try? FileManager.default.removeItem(at: binary) }
        let info = AmooBuildInfo.capture(executableURL: binary)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: binary.path
        )
        XCTAssertNotNil(info.replacedBinaryDate())
        XCTAssertTrue(info.stalenessWarning()?.contains("restart") == true)
    }

    func testResolvesSymbolicAndPackedHead() throws {
        let gitDir = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: gitDir) }
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "0123456789abcdef0123 refs/heads/main\n".write(
            to: gitDir.appendingPathComponent("packed-refs"), atomically: true, encoding: .utf8
        )
        XCTAssertEqual(AmooBuildInfo.resolveHead("ref: refs/heads/main", gitDir: gitDir), "0123456789ab")
        XCTAssertEqual(AmooBuildInfo.resolveHead("fedcba9876543210", gitDir: gitDir), "fedcba987654")
    }
}
