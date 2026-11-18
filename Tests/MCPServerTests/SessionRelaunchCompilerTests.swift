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

    /// A later launch that drops only a state-reset key from the session's own launch is a relaunch
    /// that keeps state; the dropped keys travel with it so generation can check them.
    func testALaterLaunchDroppingEnvironmentKeysIsARelaunchThatNamesThem() throws {
        let operations = try compileLaunch(environment: "AUTOMATED=1,SKIP=1").studioTest.compiledPlan?.toolOperations
        XCTAssertEqual(operations?.map(\.tool), ["relaunch_application", "assert_visible"])
        XCTAssertEqual(operations?.first?.arguments["without_environment"], "RESET")
    }

    func testALaterLaunchThatChangesAValueOrRunsOnAndroidStaysExcluded() throws {
        let changed = try compileLaunch(environment: "AUTOMATED=0,SKIP=1")
        XCTAssertEqual(changed.studioTest.compiledPlan?.toolOperations?.map(\.tool), ["assert_visible"])
        XCTAssertEqual(changed.studioTest.compiledPlan?.excludedWarnings.count, 1)

        let android = try compileLaunch(environment: "AUTOMATED=1,SKIP=1", platform: "android")
        XCTAssertEqual(android.studioTest.compiledPlan?.toolOperations?.map(\.tool), ["assert_visible"])
    }

    private func compileLaunch(environment: String, platform: String = "ios") throws -> CompileSessionToPlanResult {
        let now = Date()
        let actions: [SessionAction] = [
            .init(
                timestamp: now, toolName: "device_launch_app",
                arguments: ["app_id": "com.example.app", "environment": environment],
                result: "ok", isError: false
            ),
            .init(timestamp: now, toolName: "assert_visible", arguments: ["id": "habit"], result: "ok", isError: false)
        ]
        let report = SessionReport(
            sessionID: "session", appID: "com.example.app", deviceID: "device", platform: platform,
            startedAt: now, endedAt: now, durationSeconds: 1, actionCount: 2, errorCount: 0,
            isActive: false, actions: actions,
            launchEnvironment: ["AUTOMATED": "1", "SKIP": "1", "RESET": "1"]
        )
        return try SessionPlanCompiler.compile(report: report, testName: "Persistence", testDescription: "")
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
