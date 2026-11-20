// swiftlint:disable multiline_arguments
import AmooCore
@testable import AmooTools
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

    /// Answers its first `fastReads` queries at once with no match, then takes two seconds per query.
    private actor SlowingDriver: PlatformDriver {
        private let fastReads: Int
        private var reads = 0

        init(fastReads: Int) {
            self.fastReads = fastReads
        }

        func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
            try await findElements(selector, appID: nil)
        }

        func findElements(_: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
            reads += 1
            if reads > fastReads {
                try await Task.sleep(for: .seconds(2))
            }
            return []
        }

        func getScreenContext() async throws -> ScreenContext {
            ScreenContext(summary: "settings")
        }
    }

    func testATimeoutDuringALaterPollIsAMismatchNotADeviceProblem() async {
        let result = await DriverToolExecutor(driver: SlowingDriver(fastReads: 1)).execute(
            toolName: "assert_visible", arguments: ["id": "jot.settings.data.import", "timeout_ms": "300"]
        )
        let fields = result.structuredContent?.objectValue
        XCTAssertTrue(result.isError)
        XCTAssertEqual(fields?["failure_kind"], .string("assertion_mismatch"), result.content)
        XCTAssertEqual(fields?["companion_health"], .string("responded"))
    }

    func testAFirstPollThatNeverAnswersIsStillAnObservationFailure() async {
        let result = await DriverToolExecutor(driver: SlowingDriver(fastReads: 0)).execute(
            toolName: "assert_visible", arguments: ["id": "jot.settings.data.import", "timeout_ms": "300"]
        )
        XCTAssertEqual(result.structuredContent?.objectValue?["failure_kind"], .string("observation_failed"))
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
