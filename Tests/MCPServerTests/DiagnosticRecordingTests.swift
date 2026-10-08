import AmooCore
import Foundation
import MCP
@testable import MCPServer
@testable import SessionCompiler
import TestCommons
import TestSession
import XCTest

// Compact fixtures keep persistence and recording expectations together.
// swiftlint:disable multiline_arguments

final class DiagnosticRecordingTests: XCTestCase {
    func testInspectionEvidenceSurvivesDiskReloadAndRetroactiveSecretRedaction() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = FileSessionStore(root: scratch.url.appending(path: "sessions"))
        let manager = SessionManager(bootstrapper: MockSessionBootstrapper(), store: store)
        let session = try await manager.startSession(appID: "com.example.frontmost", platform: .ios)
        let driver = try XCTUnwrap(session.driver as? MockDriver)
        await driver.stubAccessibilityInspection(AccessibilityInspection(
            status: "observed", provider: "appleVoiceOver", utterances: ["Forward secret", "Backward secret"],
            originalVoiceOverEnabled: false, restoredVoiceOverEnabled: false,
            requestedChecks: ["phase.0", "phase.1"], evaluatedChecks: ["phase.0", "phase.1"],
            phases: [
                .init(phaseIndex: 0, direction: "forward", requestedSteps: 1, utterances: ["Forward secret"]),
                .init(phaseIndex: 1, direction: "backward", requestedSteps: 1, utterances: ["Backward secret"])
            ]
        ))
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        let result = await executor.execute(toolName: "test_voiceover", arguments: [
            "session_id": session.id, "app_id": session.appID, "record_speech": "true",
            "phases": #"[{"steps":1,"direction":"forward"},{"steps":1,"direction":"backward"}]"#
        ])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["verdict"], .string("notAssessed"))
        await session.registerSecret("secret")
        try await manager.endSession(session.id)
        let restarted = SessionManager(bootstrapper: MockSessionBootstrapper(), store: store)
        let reloaded = await restarted.report(for: session.id)
        let loaded = try XCTUnwrap(reloaded)
        let action = try XCTUnwrap(loaded.actions.first)
        XCTAssertEqual(action.intent, .diagnostic)
        XCTAssertTrue(action.diagnosticEvidence?.speechRetained == true)
        let text = try XCTUnwrap(String(bytes: SessionReport.makeJSONEncoder().encode(loaded), encoding: .utf8))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertTrue(text.contains("Backward <redacted>"))
        let plan = try SessionPlanCompiler.compile(report: loaded, testName: "Speech", testDescription: nil)
        XCTAssertTrue(plan.studioTest.compiledPlan?.excludedWarnings.isEmpty == true)
        XCTAssertTrue(plan.studioTest.compiledPlan?.toolOperations?.isEmpty == true)
    }

    func testFailedAuditRemainsDiagnosticAndRetainsStructuredFailure() async throws {
        let manager = SessionManager(bootstrapper: MockSessionBootstrapper())
        let session = try await manager.startSession(appID: "com.example.frontmost", platform: .ios)
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        let result = await executor.execute(toolName: "audit_accessibility_native", arguments: [
            "app_id": session.appID, "session_id": session.id
        ])
        XCTAssertTrue(result.isError)
        let report = await SessionReport.make(from: session)
        XCTAssertEqual(report.actions.first?.intent, .diagnostic)
        XCTAssertNotNil(report.actions.first?.diagnosticEvidence)
        try await manager.endSession(session.id)
    }

    func testAssistantDiagnosticsAreRetainedWithoutPassingVerdictOrGeneratedSteps() async throws {
        let manager = SessionManager(bootstrapper: MockSessionBootstrapper())
        let session = try await manager.startSession(appID: "com.example.frontmost", platform: .ios)
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        for tool in ["analyze_ai_testability", "highlight_a11y_issues", "suggest_test_actions"] {
            let result = await executor.execute(toolName: tool, arguments: ["session_id": session.id])
            XCTAssertFalse(result.isError, result.content)
            XCTAssertEqual(result.structuredContent?.objectValue?["verdict"], .string("notAssessed"))
            XCTAssertFalse(result.content.contains("No accessibility issues found"))
        }
        let report = await SessionReport.make(from: session)
        XCTAssertEqual(report.actions.count, 3)
        XCTAssertTrue(report.actions.allSatisfy { $0.intent == .diagnostic && $0.diagnosticEvidence != nil })
        let plan = try SessionPlanCompiler.compile(report: report, testName: "Diagnostics", testDescription: nil)
        XCTAssertTrue(plan.studioTest.compiledPlan?.excludedWarnings.isEmpty == true)
        XCTAssertTrue(plan.studioTest.compiledPlan?.toolOperations?.isEmpty == true)
        try await manager.endSession(session.id)
    }
}

extension MockDriver {
    func stubAccessibilityInspection(_ response: AccessibilityInspection) {
        inspectionResponse = response
    }

    func inspectVoiceOver(appID _: String, phases _: [VoiceOverPhase]) async throws -> AccessibilityInspection {
        inspectionResponse ?? AccessibilityInspection(status: "unsupported", provider: "platform")
    }
}

// swiftlint:enable multiline_arguments
