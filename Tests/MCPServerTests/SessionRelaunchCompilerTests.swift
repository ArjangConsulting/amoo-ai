// swiftlint:disable multiline_arguments
import SessionCompiler
import StudioProtocol
import TestSession
import XCTest

final class SessionRelaunchCompilerTests: XCTestCase {
    func testSuccessfulPairCompilesWithoutLosingFollowingAssertion() throws {
        let result = try compile(appID: "com.example.app")
        XCTAssertEqual(
            result.studioTest.compiledPlan?.toolOperations?.map(\.tool),
            ["relaunch_application", "assert_visible"]
        )
        XCTAssertTrue(result.studioTest.compiledPlan?.excludedWarnings.isEmpty == true)
        XCTAssertEqual(result.testFlow.steps.count, 3)
    }

    func testOtherAppLifecycleRemainsExcluded() throws {
        let result = try compile(appID: "com.other.app")
        XCTAssertEqual(result.studioTest.compiledPlan?.excludedWarnings.count, 2)
    }

    private func compile(appID: String) throws -> CompileSessionToPlanResult {
        let now = Date()
        let actions: [SessionAction] = [
            .init(
                timestamp: now,
                toolName: "device_terminate_app",
                arguments: ["app_id": appID],
                result: "ok",
                isError: false
            ),
            .init(
                timestamp: now,
                toolName: "device_launch_app",
                arguments: ["app_id": appID],
                result: "ok",
                isError: false
            ),
            .init(timestamp: now, toolName: "assert_visible", arguments: ["id": "habit"], result: "ok", isError: false)
        ]
        let report = SessionReport(
            sessionID: "session", appID: "com.example.app", deviceID: "device", platform: "ios",
            startedAt: now, endedAt: now, durationSeconds: 1, actionCount: 3, errorCount: 0,
            isActive: false, actions: actions
        )
        return try SessionPlanCompiler.compile(report: report, testName: "Persistence", testDescription: "")
    }
}

// swiftlint:enable multiline_arguments
