import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestSession
import XCTest

private struct FeedbackBootstrapper: SessionBootstrapper {
    func bootstrap(_: SessionBootstrapRequest) async throws -> BootstrapResult {
        BootstrapResult(driver: ReliabilityVerificationDriver(), deviceID: "fixture", platform: .ios, cleanup: {})
    }

    func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
        [DeviceInfo(id: "fixture", name: "Fixture", platform: .ios, osVersion: "27", state: .booted)]
    }

    func deviceLeases() async -> [String: SessionDeviceLease] {
        ["fixture": SessionDeviceLease(
            owner: "amoo-init",
            runtimeID: "runtime-fixture",
            expiresAt: "2030-01-01T00:00:00Z"
        )]
    }
}

private struct UnleasedBootstrapper: SessionBootstrapper {
    func bootstrap(_: SessionBootstrapRequest) async throws -> BootstrapResult {
        BootstrapResult(driver: ReliabilityVerificationDriver(), deviceID: "fixture", platform: .ios, cleanup: {})
    }

    func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
        [DeviceInfo(id: "fixture", name: "Fixture", platform: .ios, osVersion: "27", state: .booted)]
    }
}

final class VerificationFeedbackTests: XCTestCase {
    func testInvalidRunIDHasConcreteUUIDExample() async {
        let result = await DriverToolExecutor(driver: MockDriver()).execute(
            toolName: "start_session",
            arguments: ["app_id": "app", "run_id": "practice-settings-ios"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("UUID"), result.content)
        XCTAssertTrue(result.content.contains("550e8400-e29b-41d4-a716-446655440000"), result.content)
    }

    func testFreshInstallWithoutArtifactFailsBeforeBootstrap() async {
        let bootstrapper = MockSessionBootstrapper()
        let executor = DriverToolExecutor(
            driver: MockDriver(),
            sessionManager: SessionManager(bootstrapper: bootstrapper)
        )
        let result = await executor.execute(
            toolName: "start_session",
            arguments: ["app_id": "app", "fresh_install": "true"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("requires build_path"))
        let driver = await bootstrapper.lastDriver
        XCTAssertNil(driver)
    }

    func testPreconditionFailureDoesNotBecomeProductFailureAndUsageIsEmbedded() async throws {
        let manager = SessionManager(bootstrapper: FeedbackBootstrapper())
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        let started = await executor.execute(
            toolName: "start_session",
            arguments: ["app_id": "app", "checks": "[\"default\"]", "environment": "LANG=en_US.UTF-8"]
        )
        let id = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)
        _ = await executor.execute(
            toolName: "assert_visible",
            arguments: [
                "session_id": id,
                "check_id": "default",
                "id": "missing",
                "timeout_ms": "0",
                "precondition": "true"
            ]
        )
        _ = await executor.execute(toolName: "end_session", arguments: ["session_id": id])
        let snapshot = await manager.report(for: id)
        let stored = try XCTUnwrap(snapshot)
        let decoded = try SessionReport.makeJSONDecoder().decode(
            SessionReport.self, from: SessionReport.makeJSONEncoder().encode(stored)
        )
        XCTAssertEqual(decoded.provenance?["run_id"], started.structuredContent?.objectValue?["run_id"]?.stringValue)
        let result = await executor.execute(toolName: "get_verification_report", arguments: ["session_id": id])
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(fields["status"], .string("blocked"))
        XCTAssertEqual(fields["completed_checks"], .int(0))
        XCTAssertEqual(fields["checks"]?.arrayValue?.first?.objectValue?["outcome"], .string("preconditionFailed"))
        XCTAssertEqual(fields["usage"]?.objectValue?["client_calls"], .int(3))
        XCTAssertNotNil(fields["wall_time_seconds"])
        XCTAssertEqual(fields["provenance"]?.objectValue?["locale"], .string("en_US.UTF-8"))
    }

    func testLeasesAppearBeforeSessionStartup() async throws {
        let executor = DriverToolExecutor(
            driver: MockDriver(), sessionManager: SessionManager(bootstrapper: FeedbackBootstrapper())
        )
        let result = await executor.execute(toolName: "list_devices", arguments: [:])
        let device = try XCTUnwrap(result.structuredContent?.objectValue?["devices"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(device["lease"]?.objectValue?["owner"], .string("amoo-init"))
        XCTAssertEqual(device["lease"]?.objectValue?["expiresAt"], .string("2030-01-01T00:00:00Z"))
        XCTAssertTrue(result.content.contains("amoo-init"))
    }

    func testUnleasedDeviceOmitsLeaseSoTheOutputSchemaValidates() async throws {
        let executor = DriverToolExecutor(
            driver: MockDriver(), sessionManager: SessionManager(bootstrapper: UnleasedBootstrapper())
        )
        let result = await executor.execute(toolName: "list_devices", arguments: [:])
        let device = try XCTUnwrap(result.structuredContent?.objectValue?["devices"]?.arrayValue?.first?.objectValue)
        XCTAssertNil(device["lease"])
        XCTAssertTrue(result.content.contains("free"), result.content)
    }

    func testPreconditionSuccessAloneDoesNotPassRequirement() async throws {
        let executor = DriverToolExecutor(
            driver: MockDriver(), sessionManager: SessionManager(bootstrapper: FeedbackBootstrapper())
        )
        let started = await executor.execute(
            toolName: "start_session", arguments: ["app_id": "app", "checks": "[\"default\"]"]
        )
        let id = try XCTUnwrap(started.structuredContent?.objectValue?["session_id"]?.stringValue)
        _ = await executor.execute(
            toolName: "assert_visible",
            arguments: ["session_id": id, "check_id": "default", "id": "settings", "precondition": "true"]
        )
        let result = await executor.execute(toolName: "get_verification_report", arguments: ["session_id": id])
        XCTAssertEqual(result.structuredContent?.objectValue?["status"], .string("blocked"))
    }

    func testExplicitBehaviorAssertionCanCompleteCoverageAfterSetupRecovery() {
        var coverage = VerificationCoverage(checks: ["default"])
        coverage.record(id: "default", outcome: .preconditionFailed, reason: "Dirty state", evidence: [])
        XCTAssertEqual(coverage.status, "blocked")
        coverage.record(id: "default", outcome: .passed, reason: "Behavior verified", evidence: [])
        XCTAssertEqual(coverage.status, "pass")
    }
}
