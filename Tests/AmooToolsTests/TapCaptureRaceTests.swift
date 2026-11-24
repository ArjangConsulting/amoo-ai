import AmooCore
@testable import AmooTools
import XCTest

/// On Android, a read taken while text streams in can fail with "Accessibility hierarchy changed
/// during capture". `tap_element` ended at once on it and reported `dispatch_status: unknown`, so a
/// caller could not tell whether the tap had landed.
final class TapCaptureRaceTests: XCTestCase {
    private let arguments = ["label": "Send", "check_hittable": "false", "check_effect": "false"]

    func testAReadThatRacedAChangingTreeIsRetriedAndTheTapIsSentOnce() async {
        let driver = RacingDriver(races: 2)
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "tap_element", arguments: arguments)
        XCTAssertFalse(result.isError, result.content)
        let taps = await driver.taps
        XCTAssertEqual(taps, 1)
    }

    func testARaceThatOutlastsTheTimeoutIsReportedAsNotDispatched() async {
        let driver = RacingDriver(races: .max)
        var arguments = arguments
        arguments["timeout_ms"] = "600"
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "tap_element", arguments: arguments)
        let fields = result.structuredContent?.objectValue
        XCTAssertTrue(result.isError)
        XCTAssertEqual(fields?["dispatch_status"], .string("not_dispatched"), result.content)
        XCTAssertEqual(fields?["last_successful_stage"], .string("request_received"))
        XCTAssertFalse(result.content.contains("dispatch/application is unknown"), result.content)
        XCTAssertTrue(result.content.contains("hierarchy changed during capture"), result.content)
        let taps = await driver.taps
        XCTAssertEqual(taps, 0)
        let reads = await driver.reads
        XCTAssertGreaterThan(reads, 1, "retried until the timeout")
    }
}

private actor RacingDriver: PlatformDriver {
    private var races: Int
    private(set) var reads = 0
    private(set) var taps = 0

    init(races: Int) {
        self.races = races
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        try await findElements(selector, appID: nil)
    }

    func findElements(_: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
        reads += 1
        if races > 0 {
            races -= 1
            throw AmooError.commandFailed(
                command: "findElements", output: "unknown: \"Accessibility hierarchy changed during capture\""
            )
        }
        return [ElementInfo(id: "", label: "Send", type: .button, frame: Rect(x: 0, y: 0, width: 100, height: 40))]
    }

    func tap(at _: Point) async throws {
        taps += 1
    }

    func currentApp() async throws -> CurrentApp {
        CurrentApp(bundleID: "com.example.app", targetBundleID: "com.example.app")
    }
}
