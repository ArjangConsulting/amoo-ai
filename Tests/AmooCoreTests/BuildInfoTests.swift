@testable import AmooCore
import Foundation
import TestCommons
import XCTest

final class BuildInfoTests: XCTestCase {
    private func makeBinary() throws -> URL {
        let scratch = try TemporaryDirectory()
        addTeardownBlock { try? scratch.remove() }
        return try scratch.write(Data("v1".utf8), named: "amoo-bin")
    }

    func testFreshBinaryIsNotStale() throws {
        let binary = try makeBinary()
        let info = AmooBuildInfo.capture(executableURL: binary)
        XCTAssertNil(info.replacedBinaryDate())
        XCTAssertNil(info.stalenessWarning())
    }

    /// Regression: MCP servers started before a fix kept serving old code with no sign of it.
    func testRebuiltBinaryIsReportedStale() throws {
        let binary = try makeBinary()
        let info = AmooBuildInfo.capture(executableURL: binary)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: binary.path
        )
        XCTAssertNotNil(info.replacedBinaryDate())
        XCTAssertTrue(info.stalenessWarning()?.contains("restart") == true)
    }

    func testAtomicReplacementWithPreservedModificationTimeIsStale() throws {
        let binary = try makeBinary()
        let info = AmooBuildInfo.capture(executableURL: binary)
        try Data("v2".utf8).write(to: binary, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: XCTUnwrap(info.binaryModifiedAt)],
            ofItemAtPath: binary.path
        )
        XCTAssertNotNil(info.replacedBinaryDate())
        XCTAssertEqual(info.binarySHA256, sha256Hex(Data("v1".utf8)))
    }

    func testResolvesSymbolicAndPackedHead() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let gitDir = scratch.url
        try "0123456789abcdef0123 refs/heads/main\n".write(
            to: gitDir.appendingPathComponent("packed-refs"), atomically: true, encoding: .utf8
        )
        XCTAssertEqual(AmooBuildInfo.resolveHead("ref: refs/heads/main", gitDir: gitDir), "0123456789ab")
        XCTAssertEqual(AmooBuildInfo.resolveHead("fedcba9876543210", gitDir: gitDir), "fedcba987654")
    }
}
