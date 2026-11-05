import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestCommons
import TestSession
import XCTest

private struct TelemetryFailingBootstrapper: SessionBootstrapper {
    func bootstrap(_: SessionBootstrapRequest) async throws -> BootstrapResult {
        throw AmooError.commandFailed(command: "startup", output: "fixture failure")
    }

    func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
        []
    }
}

final class RunTelemetryTests: XCTestCase {
    func testRunCountsFailedStartupAndValidationAcrossExecutorRestarts() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let runID = UUID().uuidString
        let manager = SessionManager(bootstrapper: TelemetryFailingBootstrapper())
        let executor = DriverToolExecutor(
            driver: MockDriver(), sessionManager: manager, runTelemetry: RunTelemetryStore(directory: scratch.url)
        )
        let startup = await executor.execute(toolName: "start_session", arguments: ["app_id": "app", "run_id": runID])
        XCTAssertTrue(startup.isError)
        XCTAssertEqual(startup.structuredContent?.objectValue?["run_id"], .string(runID))
        _ = await executor.execute(toolName: "tap", arguments: ["run_id": runID, "x": "invalid", "y": "0"])
        let restarted = DriverToolExecutor(
            driver: MockDriver(),
            runTelemetry: RunTelemetryStore(directory: scratch.url)
        )
        let result = await restarted.execute(toolName: "get_run_telemetry", arguments: ["run_id": runID])
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        let metrics = try XCTUnwrap(fields["metrics"]?.objectValue)
        XCTAssertEqual(metrics["client_calls"], .int(2))
        XCTAssertEqual(metrics["failed_calls"], .int(2))
        XCTAssertEqual(metrics["startup_attempts"], .int(1))
        XCTAssertEqual(metrics["failed_startups"], .int(1))
        XCTAssertEqual(metrics["unfinished_calls"], .int(0))
        XCTAssertEqual(metrics["image_bytes"], .int(0))
        XCTAssertGreaterThan(metrics["text_payload_bytes"]?.intValue ?? 0, 0)
        XCTAssertEqual(fields["recording_health"], .string("saved"))
        XCTAssertEqual(fields["model_token_usage"], .null)
    }

    func testUnfinishedCallsSurviveAnotherLedgerInstanceAndRunsStayIsolated() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let first = RunTelemetryStore(directory: scratch.url)
        let runID = UUID().uuidString
        _ = await first.begin(runID: runID, tool: "start_session", sessionID: nil)
        _ = await first.begin(runID: UUID().uuidString, tool: "start_session", sessionID: nil)
        let second = RunTelemetryStore(directory: scratch.url)
        let report = await second.snapshot(runID: runID, excluding: nil)
        XCTAssertEqual(report.totals["client_calls"], 1)
        XCTAssertEqual(report.totals["unfinished_calls"], 1)
        XCTAssertEqual(report.totals["startup_attempts"], 1)
    }

    func testSessionInheritsRunAndBatchDoesNotDoubleCountClientCalls() async throws {
        let manager = SessionManager(bootstrapper: MockSessionBootstrapper())
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        let runID = UUID().uuidString
        let started = await executor.execute(toolName: "start_session", arguments: ["app_id": "app", "run_id": runID])
        let sessionID = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)
        let batch = await executor.execute(toolName: "run_steps", arguments: [
            "session_id": sessionID, "steps": "[{\"tool\":\"tap\",\"arguments\":{\"x\":1,\"y\":1}}]"
        ])
        XCTAssertFalse(batch.isError, batch.content)
        _ = await executor.execute(toolName: "end_session", arguments: ["session_id": sessionID])
        let report = await executor.execute(toolName: "get_run_telemetry", arguments: ["run_id": runID])
        let metrics = report.structuredContent?.objectValue?["metrics"]?.objectValue
        XCTAssertEqual(metrics?["client_calls"], .int(3))
        XCTAssertEqual(metrics?["operations"], .int(1))
    }
}
