import AmooCore
import Foundation
@testable import MCPServer
import StudioProtocol
import TestSession
import XCTest

final class SessionPlanCompilerTests: XCTestCase {
    private func makeAction(
        tool: String,
        arguments: [String: String] = [:],
        isError: Bool = false
    ) -> SessionAction {
        SessionAction(timestamp: Date(), toolName: tool, arguments: arguments, result: "ok", isError: isError)
    }

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
            errorCount: actions.filter(\.isError).count,
            isActive: false,
            actions: actions
        )
    }

    func testHappyPathTranslatesRecognizedTools() throws {
        let report = makeReport(actions: [
            makeAction(tool: "tap_element", arguments: ["id": "submit-button"]),
            makeAction(tool: "type_text", arguments: ["text": "hello"]),
            makeAction(tool: "assert_visible", arguments: ["description": "Welcome screen"]),
            makeAction(tool: "take_screenshot")
        ])

        let result = SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        XCTAssertEqual(result.testFlow.platform, "ios")
        XCTAssertEqual(result.testFlow.deviceID, "device-1")
        XCTAssertEqual(result.testFlow.steps.map(\.tool), [
            "tap_element", "type_text", "assert_visible", "take_screenshot"
        ])
        XCTAssertEqual(result.testFlow.steps[0].arguments["id"], "submit-button")

        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)
        XCTAssertEqual(operations.map(\.tool), ["tap_element", "type_text", "assert_visible", "take_screenshot"])
        XCTAssertEqual(operations[2].arguments["contains_text"], "Welcome screen")
        XCTAssertNil(operations[2].arguments["description"])

        XCTAssertEqual(result.studioTest.steps.count, 4)
        XCTAssertEqual(result.studioTest.platform, "ios")
        XCTAssertEqual(result.studioTest.requirements?.appId, "com.example.app")

        // assert_visible is flagged approximate (description -> contains_text), everything else is clean.
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings[0].toolName, "assert_visible")
    }

    func testRedactedValuePassesThroughWithWarning() {
        let report = makeReport(actions: [
            makeAction(tool: "set_text", arguments: ["id": "password-field", "value": "<redacted, 8 chars>"])
        ])

        let result = SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        let operation = result.studioTest.compiledPlan?.toolOperations?.first
        XCTAssertEqual(operation?.arguments["value"], "<redacted, 8 chars>")
        XCTAssertEqual(result.testFlow.steps.first?.arguments["value"], "<redacted, 8 chars>")
        XCTAssertTrue(result.warnings.contains { $0.reason.contains("redacted") })
    }

    func testUntranslatableCoordinateTapIsExcludedFromCompiledPlanButKeptInFlow() {
        let report = makeReport(actions: [
            makeAction(tool: "tap", arguments: ["x": "10", "y": "20"])
        ])

        let result = SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        XCTAssertEqual(result.testFlow.steps.map(\.tool), ["tap"])
        XCTAssertEqual(result.studioTest.compiledPlan?.toolOperations, [])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings[0].toolName, "tap")
        XCTAssertTrue(result.warnings[0].reason.contains("no Studio tool equivalent"))
    }

    func testDescriptionOnlyAssertionsRetainAStudioSelector() throws {
        let report = makeReport(actions: [
            makeAction(tool: "assert_absent", arguments: ["description": "Loading spinner"]),
            makeAction(
                tool: "assert_value",
                arguments: ["description": "Account status", "expected": "Active"]
            )
        ])

        let result = SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)

        XCTAssertEqual(operations.map(\.tool), ["assert_not_visible", "assert_text"])
        XCTAssertEqual(operations[0].arguments["contains_text"], "Loading spinner")
        XCTAssertEqual(operations[1].arguments["contains_text"], "Account status")
        XCTAssertEqual(operations[1].arguments["value"], "Active")
        XCTAssertTrue(result.warnings.allSatisfy { $0.reason.contains("approximate selector mapping") })
    }

    func testAssertEnabledTranslatesToStudioTool() throws {
        let report = makeReport(actions: [
            makeAction(tool: "assert_enabled", arguments: ["id": "submit-button"]),
            makeAction(tool: "assert_enabled", arguments: ["description": "Play button"])
        ])

        let result = SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)

        XCTAssertEqual(operations.map(\.tool), ["assert_enabled", "assert_enabled"])
        XCTAssertEqual(operations[0].arguments["id"], "submit-button")
        XCTAssertEqual(operations[1].arguments["contains_text"], "Play button")
        XCTAssertNil(operations[1].arguments["description"])

        // Only the description-only selector (approximate mapping) should warn.
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(result.warnings[0].toolName, "assert_enabled")
    }

    func testContainsOnlyValueAssertionIsExcludedRatherThanChangedToEquality() {
        let report = makeReport(actions: [
            makeAction(tool: "assert_value", arguments: ["id": "message", "contains": "Welcome"])
        ])

        let result = SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        XCTAssertEqual(result.testFlow.steps.map(\.tool), ["assert_value"])
        XCTAssertEqual(result.studioTest.compiledPlan?.toolOperations, [])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].reason.contains("no Studio tool equivalent"))
    }

    func testFlowEncodesRecordedDeviceUsingCLIFieldName() throws {
        let result = SessionPlanCompiler.compile(
            report: makeReport(actions: [makeAction(tool: "press_back")]),
            testName: nil,
            testDescription: nil
        )

        let data = try JSONEncoder().encode(result.testFlow)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["device_id"] as? String, "device-1")
        XCTAssertNil(json["deviceID"])
    }

    func testEmptySessionProducesEmptyResult() {
        let report = makeReport(actions: [])

        let result = SessionPlanCompiler.compile(
            report: report,
            testName: "custom-name",
            testDescription: "custom-desc"
        )

        XCTAssertEqual(result.testFlow.steps, [])
        XCTAssertEqual(result.studioTest.compiledPlan?.toolOperations, [])
        XCTAssertEqual(result.studioTest.name, "custom-name")
        XCTAssertEqual(result.studioTest.description, "custom-desc")
        XCTAssertTrue(result.warnings.isEmpty)
    }
}
