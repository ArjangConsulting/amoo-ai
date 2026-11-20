import AmooCore
@testable import AmooTools
import XCTest

/// Readiness at the two moments a step used to race the app: a control that renders a moment after
/// its screen, and the first query of a freshly launched process.
final class TapAppearanceTests: XCTestCase {
    /// The habit picker is missing for the first `missingReads` queries, then present.
    private actor LateControlDriver: PlatformDriver {
        private let missingReads: Int
        private var reads = 0
        private(set) var taps: [Point] = []
        private(set) var launched = false

        init(missingReads: Int) {
            self.missingReads = missingReads
        }

        func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
            try await findElements(selector, appID: nil)
        }

        func findElements(_ selector: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
            reads += 1
            guard reads > missingReads else { return [] }
            let picker = ElementInfo(
                id: "habit_picker",
                label: "Habit",
                type: .button,
                frame: Rect(x: 0, y: 100, width: 200, height: 44)
            )
            return selector.id == nil || selector.id == picker.id ? [picker] : []
        }

        func tap(at point: Point) async throws {
            taps.append(point)
        }

        func launchApp(appID _: String, arguments _: [String], environment _: [String: String]) async throws {
            launched = true
        }

        func currentApp() async throws -> CurrentApp {
            CurrentApp(bundleID: "com.example.jot", targetBundleID: "com.example.jot")
        }

        func getScreenContext() async throws -> ScreenContext {
            ScreenContext(summary: "day detail")
        }
    }

    func testATapWaitsBrieflyForAControlThatRendersAfterItsScreen() async {
        let driver = LateControlDriver(missingReads: 2)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "habit_picker", "check_effect": "false"]
        )
        XCTAssertFalse(result.isError, result.content)
        let taps = await driver.taps
        XCTAssertEqual(taps.count, 1)
    }

    func testATapStillFailsWhenTheControlNeverAppears() async {
        let driver = LateControlDriver(missingReads: .max)
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "habit_picker", "timeout_ms": "300"]
        )
        XCTAssertTrue(result.isError)
        let taps = await driver.taps
        XCTAssertTrue(taps.isEmpty)
    }

    /// The first query of a freshly launched app is slow (XCUITest waits for it to go idle).
    private actor SlowAfterLaunchDriver: PlatformDriver {
        private var slowNextRead = false

        func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
            try await findElements(selector, appID: nil)
        }

        func findElements(_: ElementSelector, appID _: String?) async throws -> [ElementInfo] {
            if slowNextRead {
                slowNextRead = false
                try await Task.sleep(for: .milliseconds(600))
            }
            return [ElementInfo(
                id: "home",
                label: "Home",
                type: .button,
                frame: Rect(x: 0, y: 0, width: 80, height: 44)
            )]
        }

        func launchApp(appID _: String, arguments _: [String], environment _: [String: String]) async throws {
            slowNextRead = true
        }

        func slowDownNextRead() {
            slowNextRead = true
        }

        func currentApp() async throws -> CurrentApp {
            CurrentApp(bundleID: "com.example.jot", targetBundleID: "com.example.jot")
        }

        func getScreenContext() async throws -> ScreenContext {
            ScreenContext(summary: "home")
        }
    }

    func testTheFirstReadAfterALaunchMayOutlastAShortAssertionTimeout() async {
        let executor = DriverToolExecutor(driver: SlowAfterLaunchDriver())
        let launch = await executor.execute(toolName: "device_launch_app", arguments: ["app_id": "com.example.jot"])
        XCTAssertFalse(launch.isError, launch.content)
        let first = await executor.execute(
            toolName: "assert_visible", arguments: ["id": "home", "timeout_ms": "300"]
        )
        XCTAssertFalse(first.isError, first.content)
    }

    func testOnlyTheFirstReadAfterALaunchGetsTheAllowance() async {
        let driver = SlowAfterLaunchDriver()
        let executor = DriverToolExecutor(driver: driver)
        _ = await executor.execute(toolName: "device_launch_app", arguments: ["app_id": "com.example.jot"])
        _ = await executor.execute(toolName: "assert_visible", arguments: ["id": "home", "timeout_ms": "300"])
        await driver.slowDownNextRead()
        let later = await executor.execute(
            toolName: "assert_visible", arguments: ["id": "home", "timeout_ms": "300"]
        )
        XCTAssertTrue(later.isError, "a later slow read keeps the step's own timeout")
    }
}
