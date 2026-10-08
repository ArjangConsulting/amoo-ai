// Compact fixtures preserve nested evidence/redaction expectations together.
import AmooCore
import Foundation
import MCP
@testable import MCPServer
import SessionCompiler
import TestCommons
import TestSession
import XCTest

final class AccessibilityJourneyRecordingTests: XCTestCase {
    private let input = #"""
    {"schemaVersion":1,"id":"journey","steps":[{"id":"order","kind":"order","direction":"forward",
    "speech":[{"equals":"Authored speech"}]}]}
    """#

    private func inspection() throws -> AccessibilityInspection {
        var result = try JSONDecoder().decode(AccessibilityInspection.self, from: Data(#"""
        {"status":"observed","provider":"authoredAccessibilityJourney",
         "originalVoiceOverEnabled":false,"restoredVoiceOverEnabled":false,
         "requestedChecks":["order.order.0"],"evaluatedChecks":["order.order.0"],
         "utterances":["Observed private speech"],"journey":{"schemaVersion":1,"id":"journey",
         "checks":[{"id":"order.order.0","checkpointID":"order","source":"voiceOverSpeech",
                    "outcome":"fail","expected":"Authored speech",
                    "actual":"Observed private speech","reason":"Mismatch"}],
         "checkpoints":[{"id":"order","elements":[],"utterances":["Observed private speech"]}]}}
        """#.utf8))
        result.journey?.specification = try .decodeJSON(input)
        return result
    }

    func testAuthoredFailurePersistsAsAssertionAndBlocksIncompleteExport() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = FileSessionStore(root: scratch.url.appending(path: "sessions"))
        let manager = SessionManager(bootstrapper: MockSessionBootstrapper(), store: store)
        let session = try await manager.startSession(appID: "com.example.frontmost", platform: .ios)
        let driver = try XCTUnwrap(session.driver as? MockDriver)
        try await driver.stubAccessibilityInspection(inspection())
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        let result = await executor.execute(toolName: "assert_accessibility_journey", arguments: [
            "session_id": session.id, "app_id": session.appID, "journey": input
        ])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.structuredContent?.objectValue?["verdict"], .string("fail"))
        try await manager.endSession(session.id)
        let reloaded = await SessionManager(bootstrapper: MockSessionBootstrapper(), store: store)
            .report(for: session.id)
        let report = try XCTUnwrap(reloaded)
        let action = try XCTUnwrap(report.actions.first)
        XCTAssertEqual(action.intent, .assertion)
        XCTAssertNotNil(action.diagnosticEvidence)
        let encoded = try XCTUnwrap(String(bytes: SessionReport.makeJSONEncoder().encode(report), encoding: .utf8))
        XCTAssertFalse(encoded.contains("Observed private speech"))
        XCTAssertTrue(encoded.contains("Mismatch"))
        let plan = try SessionPlanCompiler.compile(report: report, testName: "Journey", testDescription: nil)
        XCTAssertEqual(
            plan.studioTest.compiledPlan?.excludedWarnings.count,
            1,
            "A failed authored assertion cannot silently disappear from generated tests"
        )
    }

    func testPassingAuthoredAssertionAndLateSecretsSurviveRoundTrip() async throws {
        let manager = SessionManager(bootstrapper: MockSessionBootstrapper())
        let session = try await manager.startSession(appID: "com.example.frontmost", platform: .ios)
        let driver = try XCTUnwrap(session.driver as? MockDriver)
        var captured = try inspection()
        captured.journey?.checks[0].outcome = .pass
        captured.journey?.checks[0].expected = "equals: Observed private speech"
        let passingInput = input.replacingOccurrences(of: "Authored speech", with: "Observed private speech")
        captured.journey?.specification = try .decodeJSON(passingInput)
        await driver.stubAccessibilityInspection(captured)
        let executor = DriverToolExecutor(driver: MockDriver(), sessionManager: manager)
        let result = await executor.execute(toolName: "assert_accessibility_journey", arguments: [
            "session_id": session.id, "app_id": session.appID, "journey": passingInput, "record_speech": "true"
        ])
        XCTAssertFalse(result.isError, result.content)
        await session.registerSecret("private")
        let report = await SessionReport.make(from: session)
        XCTAssertEqual(report.actions.first?.intent, .assertion)
        let encoded = try XCTUnwrap(String(bytes: SessionReport.makeJSONEncoder().encode(report), encoding: .utf8))
        XCTAssertFalse(encoded.contains("private"))
        XCTAssertTrue(encoded.contains("Observed <redacted> speech"))
        try await manager.endSession(session.id)
    }

    func testInvalidJourneyAndWrongTargetCannotCallProvider() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        for arguments in [
            ["app_id": "com.example.frontmost", "journey": "{}"],
            ["app_id": "com.other", "journey": input],
            ["app_id": "com.example.frontmost", "journey": input, "record_speech": "invalid"]
        ] {
            let result = await executor.execute(toolName: "assert_accessibility_journey", arguments: arguments)
            XCTAssertTrue(result.isError)
        }
        let calls = await driver.calls
        XCTAssertFalse(calls.contains("journey"))
    }
}

extension MockDriver {
    func inspectAccessibilityJourney(
        appID _: String,
        journey: AccessibilityJourney
    ) async throws -> AccessibilityInspection {
        calls.append("journey")
        try journey.validate()
        return inspectionResponse ?? AccessibilityInspection(
            status: "unsupported",
            provider: "authoredAccessibilityJourney"
        )
    }
}
