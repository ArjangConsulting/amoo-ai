import AmooCore
import MCP
@testable import MCPServer
import XCTest

private struct FoldObservationDriver: PlatformDriver {
    func setPosture(_ posture: DevicePosture) async throws -> DevicePosture {
        posture
    }

    func screenState() async throws -> ScreenPowerState? {
        .locked
    }

    func currentApp() async throws -> CurrentApp {
        CurrentApp(bundleID: "com.android.systemui", targetBundleID: "com.example.app")
    }

    func screenGeometry() async throws -> ScreenSize {
        ScreenSize(widthPoints: 540, heightPoints: 720, widthPixels: 1080, heightPixels: 1440, scale: 2)
    }
}

final class DeviceObservationTests: XCTestCase {
    func testFoldSuccessReportsLockScreenForegroundAndActualViewportWithoutAppConfirmation() async {
        let result = await DriverToolExecutor(driver: FoldObservationDriver()).execute(
            toolName: "set_posture", arguments: ["posture": "opened"]
        )
        let fields = result.structuredContent?.objectValue
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(fields?["posture"], .string("opened"))
        XCTAssertEqual(fields?["screen_state"], .string("locked"))
        XCTAssertEqual(fields?["foreground_app_id"], .string("com.android.systemui"))
        XCTAssertEqual(fields?["viewport"]?.objectValue?["width_pixels"], .double(1080))
        XCTAssertEqual(fields?["postcondition_verified"], .bool(false))
        XCTAssertEqual(fields?["outcome_status"], .string("dispatched"))
    }

    func testNearbyCandidatesRankSplitWordsAndRetainRoles() {
        let elements = (0 ..< 15).map { ElementInfo(id: "unrelated-\($0)", label: "Other", type: .button) }
            + [ElementInfo(id: "word", label: "Grammar", type: .button)]
        let candidates = DriverToolExecutor.nearbyCandidates(elements, arguments: ["label": "Grammar explained here"])
        XCTAssertEqual(candidates.first?.id, "word")
        XCTAssertEqual(candidates.count, 8)
        XCTAssertEqual(candidates.first?.type, .button)
    }

    func testTapIsDispatchedUntilAnExplicitAssertionConfirmsTargetState() async {
        let executor = DriverToolExecutor(driver: ReliabilityVerificationDriver())
        let tap = await executor.execute(toolName: "tap_element", arguments: [
            "id": "settings", "check_effect": "false", "check_hittable": "false"
        ])
        XCTAssertFalse(tap.isError, tap.content)
        XCTAssertEqual(tap.structuredContent?.objectValue?["outcome_status"], .string("dispatched"))
        XCTAssertEqual(tap.structuredContent?.objectValue?["postcondition_verified"], .bool(false))
        let ambiguous = await executor.execute(toolName: "tap_element", arguments: ["contains_text": "Item"])
        XCTAssertEqual(ambiguous.structuredContent?.objectValue?["dispatch_status"], .string("not_dispatched"))
        XCTAssertEqual(ambiguous.structuredContent?.objectValue?["outcome_status"], .string("inconclusive"))
        let assertion = await executor.execute(toolName: "assert_visible", arguments: ["id": "settings"])
        XCTAssertEqual(assertion.structuredContent?.objectValue?["outcome_status"], .string("target_state_confirmed"))
        let missing = await executor.execute(toolName: "tap_element", arguments: ["id": "missing", "timeout_ms": "1"])
        XCTAssertEqual(missing.structuredContent?.objectValue?["outcome_status"], .string("inconclusive"))
        XCTAssertNotNil(missing.structuredContent?.objectValue?["available_controls"]?.arrayValue?.first?
            .objectValue?["role"])
    }
}
