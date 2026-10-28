import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestCommons
import XCTest

final class MCPRecoveryTests: XCTestCase {
    func testFreshServerAdvertisesItsOwnScopedDoctorWithoutCleanup() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let binary = try scratch.write(Data("v1".utf8), named: "amoo")
        let info = AmooBuildInfo.capture(executableURL: binary)
        let stdio = MCPStdioServer(server: MCPServer(), buildInfo: info)
        let metadata = try XCTUnwrap(stdio.buildMeta.objectValue)
        XCTAssertEqual(metadata["pid"], .int(Int(info.pid)))
        XCTAssertEqual(metadata["binary_path"], .string(binary.path))
        XCTAssertEqual(metadata["stale"], .bool(false))
        XCTAssertEqual(metadata["doctor_arguments"], .array(
            ["doctor", "--mcp-pid", String(info.pid), "--json"].map(Value.string)
        ))
        XCTAssertNil(metadata["stale_cleanup_arguments"])
    }

    func testBothProtocolsAdvertiseScopedCleanupWhenTheirServerBecomesStale() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let binary = try scratch.write(Data("v1".utf8), named: "amoo")
        let info = AmooBuildInfo.capture(executableURL: binary)
        let stdio = MCPStdioServer(server: MCPServer(), buildInfo: info)
        try Data("v2".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: binary.path
        )
        var failure = ToolResult.error("original failure")
        failure.structuredContent = .object(["code": .string("original_error")])
        let annotated = MCPStdioServer.annotatingStaleness(failure, buildInfo: info)
        XCTAssertTrue(annotated.content.contains("doctor --mcp-pid \(info.pid) --kill-stale --json"))
        XCTAssertTrue(annotated.content.contains("doctor --cli-only --json"))
        XCTAssertTrue(annotated.content.contains("Leave unrelated clients running"))
        XCTAssertTrue(annotated.content.hasSuffix("original failure"))
        XCTAssertTrue(annotated.isError)
        XCTAssertEqual(annotated.structuredContent, failure.structuredContent)

        let results = [stdio.modernToolResult(annotated), stdio.legacyToolResult(annotated)]
        for result in results {
            let fields = try XCTUnwrap(result.objectValue)
            let metadata = try XCTUnwrap(fields["_meta"]?.objectValue?["dev.amoo/build"]?.objectValue)
            XCTAssertEqual(metadata["stale"], .bool(true))
            XCTAssertEqual(metadata["stale_cleanup_arguments"], .array(
                ["doctor", "--mcp-pid", String(info.pid), "--kill-stale", "--json"].map(Value.string)
            ))
            XCTAssertEqual(fields["isError"], .bool(true))
            XCTAssertEqual(fields["structuredContent"], failure.structuredContent)
        }
    }
}
