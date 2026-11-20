// swiftlint:disable multiline_arguments
import Foundation
@testable import SessionCompiler
import TestSession
import XCTest

/// A tap's `expect_*` waits on the device for its postcondition, so it is the step's assertion. The
/// compiler kept only the tap, and a flow written the recommended way generated a test that tapped
/// and checked nothing.
final class TapPostconditionCompileTests: XCTestCase {
    private func compile(_ actions: [SessionAction]) throws -> CompileSessionToPlanResult {
        let report = SessionReport(
            sessionID: "s", appID: "com.example", deviceID: "d", platform: "ios",
            startedAt: Date(), endedAt: Date(), durationSeconds: 1, actionCount: actions.count, errorCount: 0,
            isActive: false, actions: actions
        )
        return try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
    }

    private func tap(_ arguments: [String: String]) -> SessionAction {
        SessionAction(timestamp: Date(), toolName: "tap_element", arguments: arguments, result: "ok", isError: false)
    }

    func testExpectationCompilesToAnAssertionAfterTheTap() throws {
        let result = try compile([tap([
            "label": "dangerous", "expect_id": "entry.headword", "expect_label": "dangerous",
            "expect_timeout_ms": "8000"
        ])])
        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)
        XCTAssertEqual(operations.map(\.tool), ["tap_element", "assert_visible"])
        XCTAssertEqual(operations.last?.arguments["id"], "entry.headword")
        XCTAssertEqual(operations.last?.arguments["label"], "dangerous")
        let warnings = result.studioTest.compiledPlan?.warnings ?? []
        XCTAssertFalse(warnings.contains { $0.reason.contains("Final mutation has no following") }, "\(warnings)")
    }

    func testExpectAbsentCompilesToAnAbsenceAssertion() throws {
        for value in ["true", "TRUE", "1", "yes"] {
            let result = try compile([tap(["id": "close", "expect_id": "sheet", "expect_absent": value])])
            let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)
            XCTAssertEqual(operations.map(\.tool), ["tap_element", "assert_not_visible"])
        }
    }

    func testTapWithoutExpectationIsUnchanged() throws {
        let result = try compile([tap(["id": "play"])])
        XCTAssertEqual(result.studioTest.compiledPlan?.toolOperations?.map(\.tool), ["tap_element"])
    }
}

// swiftlint:enable multiline_arguments
