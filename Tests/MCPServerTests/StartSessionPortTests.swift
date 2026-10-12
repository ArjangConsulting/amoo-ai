import AmooCore
import MCP
@testable import MCPServer
import TestSession
import XCTest

/// `start_session` can name the companion port, so sessions on different simulators need not share
/// one fixed port.
extension MCPServerTests {
    func testStartSessionForwardsAnExplicitPortToTheBootstrapper() async {
        let stack = makeSessionStack()
        let server = MCPServer(
            executor: DriverToolExecutor(driver: stack.defaultDriver, sessionManager: stack.manager),
            sessionManager: stack.manager
        )
        let started = await server.execute(
            toolName: "start_session",
            arguments: ["app_id": "com.example", "port": "23456"]
        )
        XCTAssertFalse(started.isError, started.content)
        let port = await stack.bootstrapper.lastRequestedPort
        XCTAssertEqual(port, 23456)
    }

    func testStartSessionWithoutAPortLeavesTheChoiceToTheBootstrapper() async {
        let stack = makeSessionStack()
        let server = MCPServer(
            executor: DriverToolExecutor(driver: stack.defaultDriver, sessionManager: stack.manager),
            sessionManager: stack.manager
        )
        let started = await server.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        XCTAssertFalse(started.isError, started.content)
        let port = await stack.bootstrapper.lastRequestedPort
        XCTAssertNil(port)
    }

    func testStartSessionRejectsAPortOutsideTheUsableRangeBeforeAnyDeviceWork() async {
        let stack = makeSessionStack()
        let server = MCPServer(
            executor: DriverToolExecutor(driver: stack.defaultDriver, sessionManager: stack.manager),
            sessionManager: stack.manager
        )
        for bad in ["80", "70000", "abc", "-1"] {
            let started = await server.execute(
                toolName: "start_session",
                arguments: ["app_id": "com.example", "port": bad]
            )
            XCTAssertTrue(started.isError, "port '\(bad)' should be rejected")
            XCTAssertTrue(
                started.content.contains("port must be a whole number between 1024 and 65535"), started.content
            )
        }
        let sessions = await stack.manager.allSessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testStartSessionSchemaDocumentsThePortArgument() {
        let definition = SessionTools.definitions.first { $0.name == "start_session" }
        XCTAssertNotNil(definition?.properties["port"])
    }
}
