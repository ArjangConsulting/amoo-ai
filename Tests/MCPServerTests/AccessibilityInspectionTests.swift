// SwiftFormat compact calls conflict with SwiftLint argument layout.
// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestCommons
import TestSession
import XCTest

final class AccessibilityInspectionTests: XCTestCase {
    func testSpeechCaptureIsNotAnAccessibilityPassAndCleanupIsIndependent() throws {
        var inspection = AccessibilityInspection(
            status: "observed", provider: "appleVoiceOver", utterances: ["Year 2026"],
            originalVoiceOverEnabled: false, restoredVoiceOverEnabled: false,
            requestedChecks: ["traversal.phase.0"], evaluatedChecks: ["traversal.phase.0"]
        )
        XCTAssertEqual(inspection.executionStatus, "succeeded")
        XCTAssertEqual(inspection.verdict, "notAssessed")
        XCTAssertEqual(inspection.cleanupStatus, "restored")
        inspection.cleanupError = "restoration failed"
        XCTAssertEqual(inspection.executionStatus, "succeeded")
        XCTAssertEqual(inspection.cleanupStatus, "failed")
        let decoded = try JSONDecoder().decode(AccessibilityInspection.self, from: JSONEncoder().encode(inspection))
        XCTAssertEqual(decoded, inspection)
        let old = try JSONDecoder().decode(
            AccessibilityInspection.self,
            from: Data(#"{"status":"pass","provider":"appleNativeAudit"}"#.utf8)
        )
        XCTAssertEqual(old.verdict, "notAssessed", "Legacy artifacts have no evaluated coverage")
    }

    func testMultiPhaseBoundsRejectEmptyOversizedAndInvalidJourneys() throws {
        try VoiceOverPhase.validate([.init(steps: 15, direction: "forward"), .init(steps: 15, direction: "backward")])
        for phases: [VoiceOverPhase] in [
            [], [.init(steps: 31, direction: "forward")], [.init(steps: 1, direction: "left")],
            [.init(steps: 20, direction: "forward"), .init(steps: 20, direction: "backward")],
            Array(repeating: .init(steps: 1, direction: "forward"), count: 7)
        ] {
            XCTAssertThrowsError(try VoiceOverPhase.validate(phases))
        }
    }

    func testStructuredEvidenceRetentionAndRedactionIncludePhaseSpeech() async throws {
        let executor = DriverToolExecutor(driver: MockDriver())
        let value = Value.object([
            "utterances": .array([.string("Year secret")]),
            "phases": .array([.object(["utterances": .array([.string("Backward secret")])])]),
            "cleanupError": .string("failure secret"), "restoredVoiceOverEnabled": .bool(false)
        ])
        let result = ToolResult(content: "observed", structuredContent: value)
        let omitted = await executor.diagnosticEvidence(toolName: "test_voiceover", arguments: [:], result: result)
        let retained = await executor.diagnosticEvidence(
            toolName: "test_voiceover",
            arguments: ["record_speech": "true"],
            result: result
        )
        let omittedData = try JSONEncoder().encode(XCTUnwrap(omitted))
        let omittedText = try XCTUnwrap(String(bytes: omittedData, encoding: .utf8))
        XCTAssertFalse(omittedText.contains("Year secret"))
        XCTAssertFalse(omittedText.contains("Backward secret"))
        var redactor = ArtifactRedactor()
        redactor.register("secret")
        let action = SessionAction(
            timestamp: Date(timeIntervalSince1970: 100.125),
            toolName: "test_voiceover",
            arguments: [:],
            result: "observed",
            isError: false,
            diagnosticEvidence: retained
        ).redacted(using: redactor)
        let encoded = try SessionReport.makeJSONEncoder().encode(action)
        let text = try XCTUnwrap(String(bytes: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertTrue(text.contains("Year <redacted>"))
        XCTAssertEqual(try SessionReport.makeJSONDecoder().decode(SessionAction.self, from: encoded), action)
        XCTAssertNotNil(action.recordingGestureTarget(.init(
            elementID: "x",
            elementLabel: nil,
            resolution: .nearestHitPoint
        )).diagnosticEvidence)
    }

    func testUnsupportedDriverCannotProducePassingCoverage() async {
        let result = await DriverToolExecutor(driver: MockDriver()).execute(
            toolName: "test_voiceover", arguments: ["app_id": "com.example.frontmost"]
        )
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("unsupported"), result.content)
    }

    func testInvalidOptionsAndWrongAppAreRejected() async {
        let executor = DriverToolExecutor(driver: MockDriver())
        for arguments in [
            ["app_id": "com.example.frontmost", "steps": "0"],
            ["app_id": "com.example.frontmost", "steps": "31"],
            ["app_id": "com.example.frontmost", "steps": "no"],
            ["app_id": "com.example.frontmost", "direction": "left"],
            ["app_id": "com.other"]
        ] {
            let result = await executor.execute(toolName: "test_voiceover", arguments: arguments)
            XCTAssertTrue(result.isError, result.content)
        }
        for categories in ["", "contrast,unknown", "contrast,"] {
            let result = await executor.execute(
                toolName: "audit_accessibility_native",
                arguments: ["app_id": "com.example.frontmost", "categories": categories]
            )
            XCTAssertTrue(result.isError)
        }
    }

    func testKnownCategoriesAndBoundedTraversalValidate() throws {
        try AccessibilityInspectionOptions.validate(
            operation: "nativeAudit",
            categories: ["trait"],
            steps: 5,
            direction: "forward"
        )
        try AccessibilityInspectionOptions.validate(
            operation: "voiceOver",
            categories: [],
            steps: 30,
            direction: "backward"
        )
        XCTAssertThrowsError(try AccessibilityInspectionOptions.validate(
            operation: "unknown",
            categories: [],
            steps: 5,
            direction: "forward"
        ))
    }

    func testSelectedAndPickerValueAreExposedWithoutInventingUnknownState() async {
        let executor = DriverToolExecutor(driver: MockDriver())
        let known = await executor.elementFields(
            .init(id: "wheel", label: "Year", value: "2026", type: .picker, isSelected: false),
            includePickerValue: true
        )
        let unknown = await executor.elementFields(.init(id: "old", label: "Year"))
        XCTAssertNotEqual(known, unknown)
        if case let .object(fields) = known {
            XCTAssertEqual(fields["selected"], .bool(false))
            XCTAssertEqual(fields["value"], .string("2026"))
        } else {
            XCTFail("Expected object")
        }
        if case let .object(fields) = unknown {
            XCTAssertNil(fields["selected"])
        } else {
            XCTFail("Expected object")
        }
    }
}

// swiftlint:enable multiline_arguments
