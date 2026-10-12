import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestSession
import XCTest

/// Ending a session, resetting a wedged companion and probing a session's health.
final class CompanionLifecycleToolTests: XCTestCase {
    private func makeServer() -> (MCPServer, MockSessionBootstrapper) {
        let bootstrapper = MockSessionBootstrapper()
        let manager = SessionManager(bootstrapper: bootstrapper)
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        return (MCPServer(executor: executor, sessionManager: manager), bootstrapper)
    }

    private func startSession(_ server: MCPServer) async throws -> String {
        let started = await server.execute(toolName: "start_session", arguments: ["app_id": "com.example"])
        return try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue, started.content)
    }

    func testEndSessionLeavesTheCompanionWarmByDefault() async throws {
        let (server, bootstrapper) = makeServer()
        let sessionID = try await startSession(server)

        let ended = await server.execute(toolName: "end_session", arguments: ["session_id": sessionID])

        XCTAssertFalse(ended.isError, ended.content)
        XCTAssertEqual(ended.structuredContent?.objectValue?["companion_stopped"]?.boolValue, false)
        let stopped = await bootstrapper.stoppedCompanions
        XCTAssertTrue(stopped.isEmpty)
    }

    func testEndSessionStopCompanionStopsItForTheSessionsDevice() async throws {
        let (server, bootstrapper) = makeServer()
        let sessionID = try await startSession(server)

        let ended = await server.execute(
            toolName: "end_session", arguments: ["session_id": sessionID, "stop_companion": "true"]
        )

        XCTAssertFalse(ended.isError, ended.content)
        XCTAssertEqual(ended.structuredContent?.objectValue?["companion_stopped"]?.boolValue, true)
        let stopped = await bootstrapper.stoppedCompanions
        XCTAssertEqual(stopped, ["ios:mock-ios"])
    }

    func testResetCompanionForwardsTheDeviceAndReportsWhatHappened() async {
        let (server, bootstrapper) = makeServer()

        let result = await server.execute(
            toolName: "reset_companion", arguments: ["platform": "ios", "device_hint": "ABC"]
        )

        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("port 23000 is free"), result.content)
        let requests = await bootstrapper.resetRequests
        XCTAssertEqual(requests, ["ios:ABC"])
    }

    func testCompanionStatusWithASessionProbesTheSessionsConnection() async throws {
        let (server, _) = makeServer()
        let sessionID = try await startSession(server)

        let result = await server.execute(toolName: "companion_status", arguments: ["session_id": sessionID])

        XCTAssertFalse(result.isError, result.content)
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(fields["status"]?.stringValue, "ready")
        XCTAssertEqual(fields["rpc_ok"]?.boolValue, true)
        XCTAssertNotNil(fields["rpc_ms"])
    }

    func testCompanionStatusForAnEndedOrUnknownSession() async throws {
        let (server, _) = makeServer()
        let sessionID = try await startSession(server)
        _ = await server.execute(toolName: "end_session", arguments: ["session_id": sessionID])

        let ended = await server.execute(toolName: "companion_status", arguments: ["session_id": sessionID])
        XCTAssertEqual(ended.structuredContent?.objectValue?["status"]?.stringValue, "closed")

        let unknown = await server.execute(toolName: "companion_status", arguments: ["session_id": "nope"])
        XCTAssertTrue(unknown.isError)
    }
}
