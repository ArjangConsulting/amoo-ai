// swiftlint:disable multiline_arguments
import Foundation
@testable import SessionCompiler
import TestCodeGenerator
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

    /// iOS reports each button of an alert twice with the same id. The device took either as the
    /// expectation met, and the generated check needed exactly one match, so the test failed where the
    /// flow passed.
    func testTheGeneratedCheckAcceptsAnyMatchAsTheDeviceDid() throws {
        let result = try compile([
            tap(["id": "submit", "expect_id": "alert.continue"]),
            tap(["id": "alert.continue", "first": "true", "expect_id": "alert.continue", "expect_absent": "true"])
        ])
        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)
        XCTAssertEqual(operations.map(\.tool), ["tap_element", "assert_visible", "tap_element", "assert_not_visible"])
        XCTAssertEqual(operations[1].arguments["first"], "true")
        XCTAssertEqual(operations[3].arguments["first"], "true")
        XCTAssertNil(operations[0].arguments["first"], "the tap's own target is never picked for the caller")

        let source = try XCUITestEmitter().generate(result.studioTest).source
        XCTAssertTrue(source.contains(".matching(identifier: \"alert.continue\").firstMatch"), source)
        XCTAssertFalse(source.contains("[\"alert.continue\"]"), "no lookup that needs exactly one match\n\(source)")
        XCTAssertTrue(source.contains("app.descendants(matching: .any)[\"submit\"]"), source)
    }

    func testTapWithoutExpectationIsUnchanged() throws {
        let result = try compile([tap(["id": "play"])])
        XCTAssertEqual(result.studioTest.compiledPlan?.toolOperations?.map(\.tool), ["tap_element"])
    }
}

// swiftlint:enable multiline_arguments
