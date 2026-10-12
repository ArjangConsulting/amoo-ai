import AmooCore
import Foundation
@testable import MCPServer
@testable import SessionCompiler
import StudioProtocol
import TestSession
import XCTest

/// How value assertions and selector approximations compile: a substring check stays a substring
/// check, and an id or label is never reported as a guess.
final class SessionPlanCompilerValueTests: XCTestCase {
    private func makeAction(tool: String, arguments: [String: String] = [:]) -> SessionAction {
        SessionAction(timestamp: Date(), toolName: tool, arguments: arguments, result: "ok", isError: false)
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
            errorCount: 0,
            isActive: false,
            actions: actions
        )
    }

    func testContainsValueAssertionCompilesAsASubstringCheckNotEquality() throws {
        let report = makeReport(actions: [
            makeAction(tool: "assert_value", arguments: ["id": "message", "contains": "Welcome"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)
        XCTAssertEqual(operations.map(\.tool), ["assert_value"])
        XCTAssertEqual(operations.first?.arguments["contains"], "Welcome")
        XCTAssertNil(operations.first?.arguments["value"], "a substring check must not become equality")
        XCTAssertEqual(result.studioTest.compiledPlan?.excludedWarnings, [])
    }

    func testScrollToElementIsAPlanStepNotAnExclusion() throws {
        let report = makeReport(actions: [
            makeAction(tool: "scroll_to_element", arguments: ["id": "row.far", "direction": "down"]),
            makeAction(tool: "tap_element", arguments: ["id": "row.far"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)
        XCTAssertEqual(operations.map(\.tool), ["scroll_to_element", "tap_element"])
        XCTAssertEqual(result.studioTest.compiledPlan?.excludedWarnings, [])
    }

    func testExactValueAssertionStillCompilesToEquality() throws {
        let report = makeReport(actions: [
            makeAction(tool: "assert_value", arguments: ["id": "message", "expected": "Welcome back"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        let operations = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations)
        let operation = try XCTUnwrap(operations.first)
        XCTAssertEqual(operation.arguments["value"], "Welcome back")
        XCTAssertNil(operation.arguments["contains"])
    }

    func testIDBasedAssertionsDoNotWarnAboutApproximateMapping() throws {
        let report = makeReport(actions: [
            makeAction(tool: "assert_visible", arguments: ["id": "home.title"]),
            makeAction(tool: "assert_visible", arguments: ["label": "Home"]),
            makeAction(tool: "assert_visible", arguments: ["description": "the home title"])
        ])

        let result = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)

        let approximate = result.warnings.filter { $0.kind == .approximate }.map(\.actionIndex)
        XCTAssertEqual(approximate, [2], "only the free-text description is a guess")
    }
}
