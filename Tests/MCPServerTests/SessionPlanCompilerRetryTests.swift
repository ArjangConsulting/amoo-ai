import AmooCore
import Foundation
@testable import MCPServer
import StudioProtocol
import TestSession
import XCTest

/// The repeated-tap collapse: its window, its tunability, and the observations that make the
/// window tunable from real recordings rather than guessed at.
final class SessionPlanCompilerRetryTests: XCTestCase {
    private func makeReport(actions: [SessionAction]) -> SessionReport {
        SessionReport(
            sessionID: "session-1",
            appID: "com.example.app",
            deviceID: "device-1",
            platform: "ios",
            startedAt: Date(),
            endedAt: Date(),
            durationSeconds: 12,
            actionCount: actions.count,
            errorCount: 0,
            isActive: false,
            actions: actions
        )
    }

    /// Builds a run of `count` identical taps spaced `gap` apart.
    private func tapRun(count: Int, gap: TimeInterval, id: String, from start: Date) -> [SessionAction] {
        (0 ..< count).map { index in
            SessionAction(
                timestamp: start.addingTimeInterval(Double(index) * gap),
                toolName: "tap_element",
                arguments: ["id": id],
                result: "ok",
                isError: false
            )
        }
    }

    func testRetryTapIntervalIsConfigurablePerCompile() throws {
        // 1.5s apart: kept at the 0.6s default, collapsed once the window is widened past it.
        let actions = tapRun(count: 3, gap: 1.5, id: "quantity.increment", from: Date())
        let report = makeReport(actions: actions)

        let defaulted = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
        XCTAssertEqual(defaulted.studioTest.compiledPlan?.toolOperations?.count, 3)

        let widened = try SessionPlanCompiler.compile(
            report: report,
            testName: nil,
            testDescription: nil,
            retryTapInterval: 2.0
        )
        XCTAssertEqual(widened.studioTest.compiledPlan?.toolOperations?.count, 1)
        XCTAssertEqual(widened.retryTapIntervalSeconds, 2.0)
    }

    func testRetryTapIntervalReadsEnvironmentOverride() {
        XCTAssertEqual(
            SessionPlanCompiler.retryTapIntervalFromEnvironment(["AMOO_RETRY_TAP_INTERVAL_MS": "1500"]),
            1.5
        )
        // Junk or non-positive values fall back rather than failing a compile.
        for junk in ["", "0", "-200", "soon"] {
            XCTAssertEqual(
                SessionPlanCompiler.retryTapIntervalFromEnvironment(["AMOO_RETRY_TAP_INTERVAL_MS": junk]),
                SessionPlanCompiler.defaultRetryTapInterval
            )
        }
    }

    /// The runs the window *declines* to collapse are the evidence that it is set too low, so they
    /// have to be reported too — otherwise there is no way to tune the threshold from recordings.
    func testRepeatedTapRunsAreReportedWhetherOrNotTheyCollapse() throws {
        let start = Date()
        let fast = tapRun(count: 3, gap: 0.2, id: "retry.button", from: start)
        let slow = tapRun(count: 2, gap: 1.5, id: "quantity.increment", from: start.addingTimeInterval(30))
        let report = makeReport(actions: fast + slow)

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        XCTAssertEqual(result.retryRunObservations.count, 2)
        let collapsed = try XCTUnwrap(result.retryRunObservations.first { $0.collapsed })
        XCTAssertEqual(collapsed.tapCount, 3)
        XCTAssertEqual(collapsed.selector, "id=retry.button")
        XCTAssertEqual(collapsed.gaps, [0.2, 0.2])

        let kept = try XCTUnwrap(result.retryRunObservations.first { $0.collapsed == false })
        XCTAssertEqual(kept.tapCount, 2)
        XCTAssertEqual(kept.gaps, [1.5])
        XCTAssertEqual(result.retryTapIntervalSeconds, SessionPlanCompiler.defaultRetryTapInterval)
    }

    func testCollapseWarningShowsTheGapsAndTheWindow() throws {
        let report = makeReport(actions: tapRun(count: 2, gap: 0.25, id: "retry.button", from: Date()))

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        let warning = try XCTUnwrap(result.warnings.first { $0.reason.contains("identical taps") })
        XCTAssertTrue(warning.reason.contains("gaps 0.25s"), warning.reason)
        XCTAssertTrue(warning.reason.contains("0.60s retry window"), warning.reason)
        XCTAssertTrue(warning.reason.contains("retry_tap_interval_ms"), warning.reason)
    }

    /// A run whose taps are not uniformly fast is ambiguous, so it is left intact rather than
    /// partially collapsed — a partial collapse would change the tap count on a guess.
    func testMixedCadenceRunIsNotPartiallyCollapsed() throws {
        let start = Date()
        let actions = [
            SessionAction(
                timestamp: start,
                toolName: "tap_element",
                arguments: ["id": "x"],
                result: "ok",
                isError: false
            ),
            SessionAction(
                timestamp: start.addingTimeInterval(0.2),
                toolName: "tap_element",
                arguments: ["id": "x"],
                result: "ok",
                isError: false
            ),
            SessionAction(
                timestamp: start.addingTimeInterval(3.0),
                toolName: "tap_element",
                arguments: ["id": "x"],
                result: "ok",
                isError: false
            )
        ]

        let result = try SessionPlanCompiler.compile(
            report: makeReport(actions: actions),
            testName: nil,
            testDescription: nil
        )

        XCTAssertEqual(result.studioTest.compiledPlan?.toolOperations?.count, 3)
        let observation = try XCTUnwrap(result.retryRunObservations.first)
        XCTAssertFalse(observation.collapsed)
        // Gaps are between consecutive taps: 0 -> 0.2 -> 3.0 is 0.2s then 2.8s.
        XCTAssertEqual(observation.gaps, [0.2, 2.8])
    }
}
