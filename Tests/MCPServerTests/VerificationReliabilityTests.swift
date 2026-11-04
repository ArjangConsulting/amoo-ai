// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestCommons
import TestSession
import XCTest

actor ReliabilityVerificationDriver: PlatformDriver {
    var taps = 0
    var deviceReads = 0
    var target = "com.example.app"

    func deviceInfo() async throws -> DeviceInfo {
        deviceReads += 1
        return DeviceInfo(id: "verification", name: "Fixture", platform: .ios, osVersion: "test", state: .booted)
    }

    func currentApp() async throws -> CurrentApp {
        CurrentApp(bundleID: target, targetBundleID: target)
    }

    func setTargetApp(bundleID: String) async throws {
        target = bundleID
    }

    func launchApp(appID: String, arguments _: [String], environment _: [String: String]) async throws {
        target = appID
    }

    func terminateApp(appID _: String) async throws {}
    func tap(at _: Point) async throws {
        taps += 1
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        let navigation = ElementInfo(
            id: "settings", label: "Account settings", type: .button,
            frame: Rect(x: 0, y: 0, width: 80, height: 44)
        )
        let content = ElementInfo(id: "content", label: "Content error", value: "Unavailable", type: .staticText)
        let rows = (0 ..< 60).map {
            ElementInfo(
                id: "row-\($0)", label: "Item \($0) with a descriptive accessible label", value: "Fixture value",
                type: .button, frame: Rect(x: 0, y: Double($0 * 44), width: 320, height: 44),
                semantics: ElementSemantics(stateDescription: "Available")
            )
        }
        return ([navigation, content] + rows).filter { element in
            (selector.id == nil || selector.id == element.id)
                && (selector.label == nil || selector.label == element.label)
                && (selector.containsText == nil || element.label.contains(selector.containsText ?? ""))
        }
    }

    func getViewHierarchy() async throws -> ViewNode {
        ViewNode(id: "root", frame: Rect(x: 0, y: 0, width: 320, height: 800))
    }
}

private struct VerificationBootstrapper: SessionBootstrapper {
    let driver: ReliabilityVerificationDriver

    func bootstrap(_: SessionBootstrapRequest) async throws -> BootstrapResult {
        BootstrapResult(driver: driver, deviceID: "verification", platform: .ios, cleanup: {})
    }

    func listDevices(platform _: Platform?) async throws -> [DeviceInfo] {
        []
    }
}

final class VerificationReliabilityTests: XCTestCase {
    private struct Harness {
        let executor: DriverToolExecutor
        let manager: SessionManager
        let driver: ReliabilityVerificationDriver
    }

    private func stack() -> Harness {
        let driver = ReliabilityVerificationDriver()
        let manager = SessionManager(bootstrapper: VerificationBootstrapper(driver: driver))
        return Harness(
            executor: DriverToolExecutor(driver: driver, sessionManager: manager),
            manager: manager,
            driver: driver
        )
    }

    private func start(_ executor: DriverToolExecutor) async throws -> String {
        let result = await executor.execute(toolName: "start_session", arguments: [
            "app_id": "com.example.app", "checks": "[\"content\",\"navigation\",\"checked\"]"
        ])
        XCTAssertFalse(result.isError, result.content)
        return try XCTUnwrap(result.structuredContent?.objectValue?["session_id"]?.stringValue)
    }

    func testDiscoveryUsesInstalledSchemasWithoutDeviceReads() async throws {
        let harness = stack()
        let executor = harness.executor
        let driver = harness.driver
        let result = await executor.execute(toolName: "get_capabilities", arguments: [
            "tool": "find_elements", "platform": "ios"
        ])
        XCTAssertFalse(result.isError, result.content)
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        let schema = try XCTUnwrap(MCPServer().toolDefinitions().first { $0.name == "find_elements" })
        XCTAssertEqual(fields["arguments"], schema.inputSchemaValue())
        XCTAssertEqual(fields["assertions"]?.objectValue?["assert_checked"], .string("unsupported"))
        XCTAssertEqual(fields["version"], .string(AmooVersion.current))
        let reads = await driver.deviceReads
        XCTAssertEqual(reads, 0)
        for profile in ToolProfile.allCases {
            XCTAssertTrue(MCPServer(profile: profile).toolNames().contains("get_capabilities"))
        }
    }

    func testAmbiguousSelectorRetainsTotalWhileBoundingCandidates() async throws {
        let harness = stack()
        let result = await harness.executor.execute(toolName: "tap_element", arguments: ["contains_text": "Item"])
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(fields["candidate_total"], .int(60))
        XCTAssertEqual(fields["candidates_truncated"], .bool(true))
        XCTAssertEqual(fields["candidates"]?.arrayValue?.count, 8)
        let taps = await harness.driver.taps
        XCTAssertEqual(taps, 0)
    }

    func testDiscoveryDistinguishesProfileAvailabilityFromProviderSupport() async {
        let harness = stack()
        let server = MCPServer(executor: harness.executor, profile: .audit)
        let discovered = await server.execute(toolName: "get_capabilities", arguments: ["tool": "tap_element"])
        XCTAssertEqual(discovered.structuredContent?.objectValue?["available_in_profile"], .bool(false))
        XCTAssertEqual(discovered.structuredContent?.objectValue?["catalog_profile"], .string("audit"))
        let unavailable = await server.execute(toolName: "tap_element", arguments: ["id": "settings"])
        XCTAssertEqual(unavailable.structuredContent?.objectValue?["code"], .string("tool_profile_unavailable"))
    }

    func testEmptyObservationReportsIdentityWithoutClaimingReadinessOrNavigationBlockage() async {
        let harness = stack()
        let result = await harness.executor.execute(toolName: "get_screen_context", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.structuredContent?.objectValue?["semantic_readiness"], .string("empty"))
        XCTAssertEqual(result.structuredContent?.objectValue?["observation_status"], .string("empty_observation"))
        XCTAssertEqual(result.structuredContent?.objectValue?["navigation_status"], .string("unassessed"))
        XCTAssertEqual(result.structuredContent?.objectValue?["target_app_id"], .string("com.example.app"))
    }

    func testGestureAndUnsupportedCheckedStateCannotCompleteRequiredCoverage() async throws {
        let harness = stack()
        let executor = harness.executor
        let manager = harness.manager
        let driver = harness.driver
        let id = try await start(executor)
        let rejected = await executor.execute(toolName: "tap", arguments: [
            "session_id": id, "x": "1", "y": "1", "check_id": "navigation"
        ])
        XCTAssertTrue(rejected.isError)
        let taps = await driver.taps
        XCTAssertEqual(taps, 0)
        let afterInvalid = await manager.report(for: id)
        XCTAssertEqual(afterInvalid?.verificationMetrics.clientCalls, 2)
        XCTAssertEqual(afterInvalid?.verificationMetrics.operations, 0)
        _ = await executor.execute(toolName: "tap", arguments: ["session_id": id, "x": "1", "y": "1"])
        _ = await executor.execute(toolName: "assert_checked", arguments: [
            "session_id": id, "id": "settings", "check_id": "checked", "timeout_ms": "50"
        ])
        let blocked = await manager.report(for: id)
        XCTAssertEqual(blocked?.verification?.status, "blocked")
        XCTAssertEqual(blocked?.verification?.checks.last?.outcome, .blocked)
        _ = await executor.execute(toolName: "assert_visible", arguments: [
            "session_id": id, "label": "Account settings", "check_id": "navigation"
        ])
        let partial = await manager.report(for: id)
        XCTAssertEqual(partial?.verification?.status, "partial")
        XCTAssertEqual(partial?.verification?.completedChecks, 1)
        XCTAssertEqual(partial?.verification?.checks.first?.outcome, .untested)
        XCTAssertFalse(partial?.verification?.checks[1].evidence.isEmpty ?? true)
        let closed = await executor.execute(toolName: "end_session", arguments: ["session_id": id])
        XCTAssertEqual(closed.structuredContent?.objectValue?["verification_status"], .string("partial"))
        let final = await executor.execute(toolName: "get_verification_report", arguments: ["session_id": id])
        XCTAssertEqual(final.structuredContent?.objectValue?["status"], .string("partial"))
        let saved = await manager.report(for: id)
        let snapshot = try XCTUnwrap(saved)
        let data = try SessionReport.makeJSONEncoder().encode(snapshot)
        let decoded = try SessionReport.makeJSONDecoder().decode(SessionReport.self, from: data)
        XCTAssertEqual(decoded.verification, snapshot.verification)
        XCTAssertGreaterThan(decoded.verificationMetrics.responseBytes, 0)
    }

    func testContentErrorDoesNotPreventIndependentNavigationChecks() async throws {
        let harness = stack()
        let executor = harness.executor
        let manager = harness.manager
        let id = try await start(executor)
        let arguments = [
            "session_id": id,
            "steps": """
            [{"tool":"assert_value","arguments":{"id":"content","expected":"Ready",
               "check_id":"content","timeout_ms":10}},
             {"tool":"assert_visible","arguments":{"label":"Account settings","check_id":"navigation"}},
             {"tool":"assert_checked","arguments":{"id":"settings","check_id":"checked","timeout_ms":50}}]
            """
        ]
        let stopped = await executor.execute(toolName: "run_steps", arguments: arguments)
        XCTAssertTrue(stopped.isError)
        let before = await manager.report(for: id)
        XCTAssertEqual(before?.verification?.completedChecks, 1)
        XCTAssertEqual(before?.verification?.checks[1].outcome, .untested)
        let result = await executor.execute(
            toolName: "run_steps", arguments: arguments.merging(["continue_on_error": "true"]) { _, value in value }
        )
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.structuredContent?.objectValue?["attempted"], .int(3))
        let report = await manager.report(for: id)
        XCTAssertEqual(report?.verification?.checks.map(\.outcome), [.failed, .passed, .blocked])
        XCTAssertEqual(report?.verification?.status, "fail")
        XCTAssertEqual(report?.verification?.completedChecks, 2)
        print("verification_coverage_continuation before=1/3 after=2/3 remaining=unsupported_checked status=fail")
        let rows = try XCTUnwrap(result.structuredContent?.objectValue?["results"]?.arrayValue)
        XCTAssertEqual(rows[1].objectValue?["structured"]?.objectValue?["passed"], .bool(true))
        XCTAssertEqual(
            rows[2].objectValue?["structured"]?.objectValue?["failure_kind"],
            .string("unsupported_property")
        )
    }

    func testSelectorMissReturnsBoundedRecoveryAndMultiwordSelectorWorks() async throws {
        let harness = stack()
        let executor = harness.executor
        let driver = harness.driver
        let missed = await executor.execute(toolName: "tap_element", arguments: ["label": "Settings guess"])
        XCTAssertTrue(missed.isError)
        let fields = try XCTUnwrap(missed.structuredContent?.objectValue)
        XCTAssertEqual(fields["observation_status"], .string("selector_miss"))
        XCTAssertEqual(fields["navigation_status"], .string("unassessed"))
        XCTAssertEqual(fields["target_app_id"], .string("com.example.app"))
        XCTAssertLessThanOrEqual(fields["available_controls"]?.arrayValue?.count ?? 100, 12)
        let matched = await executor.execute(toolName: "assert_visible", arguments: ["label": "Account settings"])
        XCTAssertFalse(matched.isError, matched.content)
        let taps = await driver.taps
        XCTAssertEqual(taps, 0)
    }

    func testCompactOutputReducesBytesWithEquivalentAssertions() async throws {
        let harness = stack()
        let executor = harness.executor
        let full = await executor.execute(toolName: "find_elements", arguments: ["limit": "60"])
        let compact = await executor.execute(toolName: "find_elements", arguments: [
            "limit": "60", "response_mode": "compact"
        ])
        let fullBytes = try JSONEncoder().encode(full.mcpResult()).count
        let compactBytes = try JSONEncoder().encode(compact.mcpResult()).count
        XCTAssertLessThan(compactBytes, fullBytes / 2)
        XCTAssertEqual(full.structuredContent?.objectValue?["total"], compact.structuredContent?.objectValue?["total"])
        let assertion = await executor.execute(toolName: "assert_visible", arguments: ["label": "Account settings"])
        let compactAssertion = await executor.execute(toolName: "assert_visible", arguments: [
            "label": "Account settings", "response_mode": "compact"
        ])
        XCTAssertEqual(assertion.structuredContent, compactAssertion.structuredContent)
        print("verification_response_bytes full=\(fullBytes) compact=\(compactBytes)")
    }

    func testMeasuredFullAndCompactVerificationKeepEquivalentCoverage() async throws {
        let steps: [[String: Any]] = [
            [
                "tool": "assert_value",
                "arguments": ["id": "content", "expected": "Ready", "check_id": "content", "timeout_ms": "10"]
            ],
            ["tool": "assert_visible", "arguments": ["label": "Account settings", "check_id": "navigation"]],
            ["tool": "assert_checked", "arguments": ["id": "settings", "check_id": "checked", "timeout_ms": "50"]]
        ]
        var snapshots: [SessionReport] = []
        for compact in [false, true] {
            let harness = stack()
            let executor = harness.executor
            let manager = harness.manager
            let id = try await start(executor)
            _ = await executor.execute(toolName: "find_elements", arguments: [
                "session_id": id, "limit": "60", "response_mode": compact ? "compact" : "full"
            ])
            if compact {
                let data = try JSONSerialization.data(withJSONObject: steps)
                _ = try await executor.execute(toolName: "run_steps", arguments: [
                    "session_id": id, "continue_on_error": "true", "result_mode": "compact",
                    "steps": XCTUnwrap(String(bytes: data, encoding: .utf8))
                ])
            } else {
                for step in steps {
                    var arguments = try XCTUnwrap(step["arguments"] as? [String: String])
                    arguments["session_id"] = id
                    _ = try await executor.execute(toolName: XCTUnwrap(step["tool"] as? String), arguments: arguments)
                }
            }
            let saved = await manager.report(for: id)
            try snapshots.append(XCTUnwrap(saved))
        }
        XCTAssertEqual(
            snapshots[0].verification?.checks.map(\.outcome),
            snapshots[1].verification?.checks.map(\.outcome)
        )
        XCTAssertEqual(snapshots.map { $0.verification?.completedChecks }, [2, 2])
        XCTAssertLessThan(
            snapshots[1].verificationMetrics.responseBytes,
            snapshots[0].verificationMetrics.responseBytes
        )
        XCTAssertEqual(snapshots.map(\.verificationMetrics.clientCalls), [5, 3])
        for (mode, snapshot) in zip(["full_sequential", "compact_batch"], snapshots) {
            let record: [String: Value] = try [
                "mode": .string(mode), "metrics": Value(snapshot.verificationMetrics),
                "completed_checks": .int(snapshot.verification?.completedChecks ?? 0),
                "required_checks": .int(3), "status": .string(snapshot.verification?.status ?? "unknown")
            ]
            let data = try JSONEncoder().encode(record)
            print("verification_comparison=" + (String(bytes: data, encoding: .utf8) ?? ""))
        }
    }
}

// swiftlint:enable multiline_arguments
