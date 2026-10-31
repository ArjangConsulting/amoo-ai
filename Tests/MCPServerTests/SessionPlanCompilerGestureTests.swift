import AmooCore
import Foundation
@testable import SessionCompiler
import StudioProtocol
import TestSession
import XCTest

final class SessionPlanCompilerGestureTests: XCTestCase {
    private func compile(_ tool: String, _ arguments: [String: String]) throws -> CompileSessionToPlanResult {
        let action = SessionAction(
            timestamp: Date(),
            toolName: tool,
            arguments: arguments,
            result: "ok",
            isError: false
        )
        let report = SessionReport(
            sessionID: "session-1",
            appID: "com.example.app",
            deviceID: "device-1",
            platform: "ios",
            startedAt: Date(),
            endedAt: Date(),
            durationSeconds: 3,
            actionCount: 1,
            errorCount: 0,
            isActive: false,
            actions: [action]
        )
        return try SessionPlanCompiler.compile(report: report, testName: "Gestures", testDescription: nil)
    }

    func testElementDragCompilesWithBothSelectorsAndTimingButNoCoordinates() throws {
        let result = try compile("drag", [
            "id": "card", "parent_id": "todo-column", "to_label": "Done", "hold_ms": "600",
            "duration_ms": "400", "check_hittable": "false"
        ])

        let operation = try XCTUnwrap(result.studioTest.compiledPlan?.toolOperations?.first)
        XCTAssertEqual(operation.tool, "drag")
        XCTAssertEqual(operation.arguments, [
            "id": "card", "parent_id": "todo-column", "to_label": "Done", "hold_ms": "600", "duration_ms": "400"
        ])
        XCTAssertEqual(result.studioTest.steps.first?.instruction, "Drag element 'card' onto 'Done'.")
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
    }

    func testDragWithACoordinateEndIsExcludedWithAnActionableReason() throws {
        let result = try compile("drag", ["id": "card", "to_x": "200", "to_y": "500"])

        XCTAssertEqual(result.studioTest.compiledPlan?.toolOperations, [])
        XCTAssertEqual(result.testFlow.steps.map(\.tool), ["drag"])
        let warning = try XCTUnwrap(result.warnings.first)
        XCTAssertEqual(warning.kind, .excluded)
        XCTAssertTrue(warning.reason.contains("to_id"), warning.reason)
    }

    func testPinchCompilesOnAnElementOrTheWholeAppButNotAtAPoint() throws {
        let element = try compile("pinch", ["id": "map", "scale": "2", "velocity": "3"])
        XCTAssertEqual(
            element.studioTest.compiledPlan?.toolOperations?.first?.arguments,
            ["id": "map", "scale": "2", "velocity": "3"]
        )
        XCTAssertEqual(element.studioTest.steps.first?.instruction, "Pinch to zoom in on element 'map'.")

        let wholeApp = try compile("pinch", ["scale": "0.5"])
        XCTAssertEqual(wholeApp.studioTest.compiledPlan?.toolOperations?.first?.arguments, ["scale": "0.5"])
        XCTAssertEqual(wholeApp.studioTest.steps.first?.instruction, "Pinch to zoom out on the app.")

        let atPoint = try compile("pinch", ["x": "10", "y": "20", "scale": "2"])
        XCTAssertEqual(atPoint.studioTest.compiledPlan?.toolOperations, [])
        XCTAssertEqual(atPoint.warnings.first?.kind, .excluded)
    }
}
