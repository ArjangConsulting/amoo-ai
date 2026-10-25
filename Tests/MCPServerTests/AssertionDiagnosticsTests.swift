// swiftlint:disable multiline_arguments
import AmooCore
import MCP
@testable import MCPServer
import XCTest

final class AssertionDiagnosticsTests: XCTestCase {
    func testUnimplementedHealthProbesRemainUnknownAndDoNotClaimRenderingReadiness() async {
        let result = await DriverToolExecutor(driver: MockDriver()).execute(
            toolName: "device_health", arguments: [:]
        )
        let fields = result.structuredContent?.objectValue
        XCTAssertFalse(result.isError)
        XCTAssertEqual(fields?["failure_scope"], .string("unknown"))
        XCTAssertEqual(fields?["render_readiness"], .string("unverified"))
        XCTAssertEqual(fields?["verdict"], .string("notAssessed"))
    }

    func testValueMismatchRetainsLastObservedStateAndExpectedValue() async {
        let driver = NavigationMockDriver(elements: [ElementInfo(id: "copy", label: "Copy", value: "Ready")])
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "assert_value", arguments: ["id": "copy", "expected": "Copied", "timeout_ms": "10"]
        )
        let fields = result.structuredContent?.objectValue
        XCTAssertTrue(result.isError)
        XCTAssertEqual(fields?["failure_kind"], .string("assertion_mismatch"))
        XCTAssertEqual(fields?["expected"], .string("Copied"))
        XCTAssertEqual(fields?["last_observed"]?.objectValue?["value"], .string("Ready"))
        XCTAssertEqual(fields?["companion_health"], .string("responded"))
    }

    func testObservationFailureDoesNotBecomeAnAssertionMismatch() async {
        let executor = DriverToolExecutor(driver: MockDriver())
        let result = await executor.assertionFailure(
            kind: .value, arguments: ["label": "Copy", "expected": "Copied"], lastMatch: nil, reads: 0,
            started: .now, observationError: "Provider timed out"
        )
        let fields = result.structuredContent?.objectValue
        XCTAssertEqual(fields?["failure_kind"], .string("observation_failed"))
        XCTAssertEqual(fields?["last_observed"], .string("unavailable"))
        XCTAssertEqual(fields?["device_health"], .string("unconfirmed"))
    }

    func testTimedOutGestureDoesNotClaimItWasNeverDispatched() async {
        let executor = DriverToolExecutor(driver: MockDriver())
        let result = await executor.executionFailureDiagnostics(
            .error("Transport timed out"), tool: "tap", started: .now, dispatchStarted: true
        )
        XCTAssertEqual(result.structuredContent?.objectValue?["dispatch_status"], .string("unknown"))
        XCTAssertTrue(result.content.contains("before retrying"))
    }

    func testSemanticFingerprintDetectsSelectionButIgnoresCaptureReferences() {
        var node = ViewNode(id: "option", isSelected: false)
        let before = DriverToolExecutor.hierarchyFingerprint(node)
        node.semantics = ElementSemantics(reference: "new-capture")
        XCTAssertEqual(before, DriverToolExecutor.hierarchyFingerprint(node))
        node.isSelected = true
        XCTAssertNotEqual(before, DriverToolExecutor.hierarchyFingerprint(node))
    }
}

// swiftlint:enable multiline_arguments
