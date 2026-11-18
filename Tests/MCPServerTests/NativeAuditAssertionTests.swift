import AmooCore
import Foundation
import MCP
@testable import MCPServer
import SessionCompiler
import TestSession
import XCTest

/// `audit_accessibility_native` reports findings by default; with `fail_on_issues` it is an
/// assertion a flow can fail on, and its reply names the elements at fault.
final class NativeAuditAssertionTests: XCTestCase {
    private func failingAudit() -> AccessibilityInspection {
        AccessibilityInspection(
            status: "fail",
            provider: "appleNativeAudit",
            issues: [
                .init(
                    category: "hitRegion",
                    description: "Hit area is too small",
                    details: "The size of this element is too small.",
                    elementID: "jot.settings.close",
                    label: "Close",
                    frame: Rect(x: 12, y: 40, width: 20, height: 20)
                ),
                .init(
                    category: "sufficientElementDescription",
                    description: "Element has no description",
                    details: "Missing useful accessibility information.",
                    elementID: nil,
                    label: nil
                )
            ],
            requestedChecks: ["hitRegion", "sufficientElementDescription"],
            evaluatedChecks: ["hitRegion", "sufficientElementDescription"]
        )
    }

    private func audit(_ arguments: [String: String]) async throws -> (ToolResult, SessionReport) {
        let manager = SessionManager(bootstrapper: MockSessionBootstrapper())
        let session = try await manager.startSession(appID: "com.example.frontmost", platform: .ios)
        let driver = try XCTUnwrap(session.driver as? MockDriver)
        await driver.stubAccessibilityInspection(failingAudit())
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        var arguments = arguments
        arguments["session_id"] = session.id
        arguments["app_id"] = session.appID
        let result = await executor.execute(toolName: "audit_accessibility_native", arguments: arguments)
        let report = await SessionReport.make(from: session)
        try await manager.endSession(session.id)
        return (result, report)
    }

    func testFindingsAreReportedWithoutFailingByDefault() async throws {
        let (result, report) = try await audit([:])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("verdict=fail"), result.content)
        XCTAssertEqual(report.actions.first?.intent, .diagnostic)
    }

    func testFailOnIssuesFailsTheCallAndRecordsAnAssertion() async throws {
        let (result, report) = try await audit(["fail_on_issues": "true"])
        XCTAssertTrue(result.isError, result.content)
        let action = try XCTUnwrap(report.actions.first)
        XCTAssertEqual(action.intent, .assertion)
        let plan = try SessionPlanCompiler.compile(report: report, testName: "Audit", testDescription: nil)
        XCTAssertEqual(
            plan.studioTest.compiledPlan?.excludedWarnings.count,
            1,
            "An audit assertion must not disappear silently from the generated test"
        )
    }

    func testTheReplyNamesEachElementAtFault() async throws {
        let (result, _) = try await audit([:])
        XCTAssertTrue(
            result.content.contains(#"- hitRegion: label "Close" id jot.settings.close at (12, 40, 20x20): Hit area"#),
            result.content
        )
        XCTAssertTrue(
            result.content.contains("- sufficientElementDescription: unnamed element: Element has no description"),
            result.content
        )
    }

    func testTheReplyListsAtMostFiveIssues() {
        let issue = AccessibilityInspection.Issue(
            category: "contrast", description: "Low contrast", details: "", elementID: nil, label: "Save"
        )
        let summary = DriverToolExecutor.issueSummary(Array(repeating: issue, count: 7))
        XCTAssertEqual(summary.split(separator: "\n").count, 6)
        XCTAssertTrue(summary.contains("2 more in structuredContent.issues"), summary)
    }
}

extension MockDriver {
    func inspectAccessibility(
        appID _: String, operation _: String, categories _: [String], steps _: Int, direction _: String
    ) async throws -> AccessibilityInspection {
        inspectionResponse ?? AccessibilityInspection(status: "unsupported", provider: "platform")
    }
}
