import AmooCore
import Foundation
import MCP
@testable import MCPServer
import StudioProtocol
import TestSession
import XCTest

extension MCPServerTests {
    func testEndSessionAutoWritesPlanArtifactsWhenStoreConfigured() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "amoo-mcp-end-session-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let stack = makeSessionStack(store: FileSessionStore(root: root))
        let manager = stack.manager
        let executor = DriverToolExecutor(driver: stack.defaultDriver, sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        let started = await server.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        let sessionID = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)
        _ = await server.execute(
            toolName: "tap_element",
            arguments: ["id": "submit-button", "session_id": sessionID]
        )

        let ended = await server.execute(toolName: "end_session", arguments: ["session_id": sessionID])
        XCTAssertFalse(ended.isError, ended.content)

        let structured = try XCTUnwrap(ended.structuredContent?.objectValue)
        let planPath = try XCTUnwrap(structured["plan_path"]?.stringValue)
        let flowPath = try XCTUnwrap(structured["flow_path"]?.stringValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: planPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flowPath))
        XCTAssertEqual(structured["warning_count"]?.intValue, 0)

        // The written plan decodes as a StudioAuthoredTest (what `amoo generate test --plan` reads).
        let planData = try Data(contentsOf: URL(fileURLWithPath: planPath))
        let plan = try JSONDecoder().decode(StudioAuthoredTest.self, from: planData)
        XCTAssertEqual(plan.compiledPlan?.toolOperations?.first?.tool, "tap_element")
    }

    func testCompileSessionToPlanResolvesSessionFromDiskAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "amoo-mcp-restart-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileSessionStore(root: root)

        // First server: run + end a session, then drop it.
        let firstStack = makeSessionStack(store: store)
        let firstExecutor = DriverToolExecutor(driver: firstStack.defaultDriver, sessionManager: firstStack.manager)
        let firstServer = MCPServer(executor: firstExecutor, sessionManager: firstStack.manager)
        let started = await firstServer.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        let sessionID = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)
        _ = await firstServer.execute(
            toolName: "tap_element",
            arguments: ["id": "submit-button", "session_id": sessionID]
        )
        _ = await firstServer.execute(toolName: "end_session", arguments: ["session_id": sessionID])

        // Second server: fresh manager over the same store.
        let secondStack = makeSessionStack(store: store)
        let secondExecutor = DriverToolExecutor(driver: secondStack.defaultDriver, sessionManager: secondStack.manager)
        let secondServer = MCPServer(executor: secondExecutor, sessionManager: secondStack.manager)

        let compiled = await secondServer.execute(
            toolName: "compile_session_to_plan",
            arguments: ["session_id": sessionID, "test_name": "named-run"]
        )
        XCTAssertFalse(compiled.isError, compiled.content)
        let name = compiled.structuredContent?.objectValue?["studioTest"]?.objectValue?["name"]?.stringValue
        XCTAssertEqual(name, "named-run")

        let report = await secondServer.execute(toolName: "get_session_report", arguments: ["session_id": sessionID])
        XCTAssertFalse(report.isError, report.content)
        XCTAssertEqual(report.structuredContent?.objectValue?["actionCount"]?.intValue, 1)
    }
}
