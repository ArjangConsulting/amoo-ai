import AmooCore
import Foundation
import MCP
@testable import MCPServer
import StudioProtocol
import TestCommons
import TestSession
import XCTest

extension MCPServerTests {
    /// A build_path typo must fail before any device/companion work, naming the path, rather than
    /// surfacing minutes later as an lstat error from simctl.
    func testStartSessionRejectsMissingBuildPathBeforeBootstrap() async {
        let stack = makeSessionStack()
        let executor = DriverToolExecutor(driver: stack.defaultDriver, sessionManager: stack.manager)
        let server = MCPServer(executor: executor, sessionManager: stack.manager)
        let missing = NSTemporaryDirectory() + "amoo-missing-\(UUID().uuidString).app"

        let result = await server.execute(
            toolName: "start_session",
            arguments: ["app_id": "com.example", "build_path": missing]
        )

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("invalid build_path"), result.content)
        XCTAssertTrue(result.content.contains(missing), result.content)
        let bootstrapped = await stack.bootstrapper.lastDriver
        XCTAssertNil(bootstrapped)
    }

    func testEndSessionAutoWritesPlanArtifactsWhenStoreConfigured() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let root = scratch.url.appending(path: "store", directoryHint: .isDirectory)

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
        XCTAssertEqual(structured["warning_count"]?.intValue, 1)

        // The written plan decodes as a StudioAuthoredTest (what `amoo generate test --plan` reads).
        let planData = try Data(contentsOf: URL(fileURLWithPath: planPath))
        let plan = try JSONDecoder().decode(StudioAuthoredTest.self, from: planData)
        XCTAssertEqual(plan.compiledPlan?.toolOperations?.first?.tool, "tap_element")
        XCTAssertEqual(plan.compiledPlan?.warnings?.count, 1)
    }

    func testCompileSessionToPlanResolvesSessionFromDiskAfterRestart() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let root = scratch.url.appending(path: "store", directoryHint: .isDirectory)
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
