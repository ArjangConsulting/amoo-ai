// swiftlint:disable multiline_arguments
import Foundation
@testable import SessionCompiler
import TestSession
import XCTest

final class AdaptiveDeviceRecordingTests: XCTestCase {
    func testConfigurationStepsReplayAndBlockIncompleteNativeExport() throws {
        let actions = [
            SessionAction(
                timestamp: Date(), toolName: "set_posture", arguments: ["posture": "closed"],
                result: "verified", isError: false
            ),
            SessionAction(
                timestamp: Date(), toolName: "set_display_preset", arguments: ["preset": "tablet"],
                result: "verified", isError: false
            )
        ]
        let report = SessionReport(
            sessionID: "adaptive", appID: "com.example.app", deviceID: "emulator-5554", platform: "android",
            startedAt: Date(), endedAt: Date(), durationSeconds: 1,
            actionCount: actions.count, errorCount: 0, isActive: false, actions: actions
        )
        let compiled = try SessionPlanCompiler.compile(report: report, testName: nil, testDescription: nil)
        XCTAssertEqual(compiled.testFlow.steps.map(\.tool), ["set_posture", "set_display_preset"])
        XCTAssertEqual(compiled.testFlow.steps.map(\.arguments), actions.map(\.arguments))
        XCTAssertEqual(
            Set(compiled.warnings.filter { $0.kind == .excluded }.map(\.toolName)),
            ["set_posture", "set_display_preset"]
        )
    }

    func testConfigurationChangesInvalidatePreviouslyRecordedCoordinates() {
        for tool in ["set_orientation", "set_posture", "set_display_preset"] {
            XCTAssertTrue(SessionPlanCompiler.invalidatesRecordedGeometry(tool), tool)
        }
    }
}

// swiftlint:enable multiline_arguments
