import Foundation
@testable import MCPServer
import TestSession
import XCTest

final class BatchExecutionTests: XCTestCase {
    func testBatchStopsAtFailureAndRecordsEachAttemptOnce() async throws {
        let bootstrapper = MockSessionBootstrapper()
        let manager = SessionManager(bootstrapper: bootstrapper)
        let session = try await manager.startSession(appID: "app", platform: .ios)
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        let result = await executor.execute(toolName: "run_steps", arguments: [
            "session_id": session.id,
            "steps": """
            [{"tool":"tap","arguments":{"x":1,"y":2}},
             {"tool":"tap","arguments":{}},
             {"tool":"press_back","arguments":{}}]
            """
        ])
        XCTAssertTrue(result.isError)
        let report = await manager.report(for: session.id)
        XCTAssertEqual(report?.actions.map(\.toolName), ["tap", "tap"])
        XCTAssertEqual(report?.errorCount, 1)
        let driver = await bootstrapper.lastDriver
        let calls = await driver?.calls
        XCTAssertEqual(calls, ["tap:1.0,2.0"])
    }

    func testNestedBatchIsRejectedBeforeAnyMutation() async throws {
        let manager = SessionManager(bootstrapper: MockSessionBootstrapper())
        let session = try await manager.startSession(appID: "app", platform: .ios)
        let result = await DriverToolExecutor(driver: MockDriver(), sessionManager: manager).execute(
            toolName: "run_steps",
            arguments: [
                "session_id": session.id,
                "steps": """
                [{"tool":"press_back","arguments":{}},{"tool":"run_steps","arguments":{}}]
                """
            ]
        )
        XCTAssertTrue(result.isError)
        let report = await manager.report(for: session.id)
        XCTAssertEqual(report?.actionCount, 0)
    }
}
