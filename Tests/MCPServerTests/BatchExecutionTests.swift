import Foundation
@testable import MCPServer
import TestCommons
import TestSession
import XCTest

final class BatchExecutionTests: XCTestCase {
    func testInvalidLaterArgumentRejectsWholeBatchBeforeMutation() async throws {
        let bootstrapper = MockSessionBootstrapper()
        let manager = SessionManager(bootstrapper: bootstrapper)
        let session = try await manager.startSession(appID: "app", platform: .ios)
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        let result = await executor.execute(toolName: "run_steps", arguments: [
            "session_id": session.id, "steps": """
            [{"tool":"tap","arguments":{"x":1,"y":2}},
             {"tool":"tap","arguments":{"x":"invalid","y":2}}]
            """
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.structuredContent?.objectValue?["argument"], .string("x"))
        let report = await manager.report(for: session.id)
        XCTAssertEqual(report?.actionCount, 0)
        let driver = await bootstrapper.lastDriver
        let calls = await driver?.calls
        XCTAssertEqual(calls, [])
    }

    func testBatchStopsAtFailureAndRecordsEachAttemptOnce() async throws {
        let bootstrapper = MockSessionBootstrapper()
        let manager = SessionManager(bootstrapper: bootstrapper)
        let session = try await manager.startSession(appID: "app", platform: .ios)
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        let result = await executor.execute(toolName: "run_steps", arguments: [
            "session_id": session.id,
            "steps": """
            [{"tool":"tap","arguments":{"x":1,"y":2}},
             {"tool":"assert_value","arguments":{"id":"content","expected":"Ready","timeout_ms":1}},
             {"tool":"press_back","arguments":{}}]
            """
        ])
        XCTAssertTrue(result.isError)
        let report = await manager.report(for: session.id)
        XCTAssertEqual(report?.actions.map(\.toolName), ["tap", "assert_value"])
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

    func testBatchCapturesImmediateScreenshotWithoutReturningInlineImage() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let output = scratch.url.appending(path: "transient.png")
        let encodedSteps = try JSONSerialization.data(withJSONObject: [
            ["tool": "tap", "arguments": ["x": 1, "y": 2]],
            [
                "tool": "take_screenshot",
                "arguments": [
                    "output": output.path,
                    "return_image": false,
                    "settle_timeout_ms": 0
                ]
            ]
        ])
        let steps = try XCTUnwrap(String(data: encodedSteps, encoding: .utf8))
        let manager = SessionManager(bootstrapper: MockSessionBootstrapper())
        let session = try await manager.startSession(appID: "app", platform: .ios)
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)

        let result = await executor.execute(toolName: "run_steps", arguments: [
            "session_id": session.id,
            "steps": steps
        ])

        XCTAssertFalse(result.isError, result.content)
        XCTAssertNil(result.image)
        XCTAssertEqual(try Data(contentsOf: output), Data([0xFF]))
        let results = try XCTUnwrap(result.structuredContent?.objectValue?["results"]?.arrayValue)
        let screenshotSummary = results[1].objectValue?["summary"]?.stringValue
        XCTAssertTrue(screenshotSummary?.contains(output.path) == true)
        let report = await manager.report(for: session.id)
        XCTAssertEqual(report?.actions.map(\.toolName), ["tap", "take_screenshot"])
    }

    func testBatchRejectsUnsavedScreenshotBeforeMutating() async throws {
        let bootstrapper = MockSessionBootstrapper()
        let manager = SessionManager(bootstrapper: bootstrapper)
        let session = try await manager.startSession(appID: "app", platform: .ios)
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        let result = await executor.execute(toolName: "run_steps", arguments: [
            "session_id": session.id,
            "steps": """
            [{"tool":"tap","arguments":{"x":1,"y":2}},
             {"tool":"take_screenshot","arguments":{"return_image":false}}]
            """
        ])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("require output and return_image=false"))
        let driver = await bootstrapper.lastDriver
        let calls = await driver?.calls
        XCTAssertEqual(calls, [])
        let report = await manager.report(for: session.id)
        XCTAssertEqual(report?.actionCount, 0)
    }
}
