import AmooCore
@testable import AmooTools
import XCTest

/// `dismiss_keyboard` never submits by default; `method=return` taps the keyboard's own return key.
final class DismissKeyboardMethodTests: XCTestCase {
    func testWithoutADismissControlItRefusesAndNamesMethodReturn() async {
        let driver = KeyboardDriver(platform: .ios)
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "dismiss_keyboard", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("method=return"), result.content)
        let actions = await driver.actions
        XCTAssertTrue(actions.isEmpty)
    }

    func testMethodReturnTapsTheKeyboardsReturnKeyNotAnAppButton() async {
        let driver = KeyboardDriver(platform: .ios)
        let result = await DriverToolExecutor(driver: driver)
            .execute(toolName: "dismiss_keyboard", arguments: ["method": "return"])
        XCTAssertFalse(result.isError, result.content)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["tap 383.0,856.0"], "the 'search' key, not the app's Done button")
    }

    func testAndroidUsesBackWithoutAnOptIn() async {
        let driver = KeyboardDriver(platform: .android)
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "dismiss_keyboard", arguments: [:])
        XCTAssertFalse(result.isError, result.content)
        let actions = await driver.actions
        XCTAssertEqual(actions, ["back"])
    }
}

/// A keyboard that closes on any of the dismissal actions, next to an app "Done" button.
actor KeyboardDriver: PlatformDriver {
    private let platform: Platform
    private var visible = true
    private(set) var actions: [String] = []

    init(platform: Platform) {
        self.platform = platform
    }

    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "device", name: "Device", platform: platform, osVersion: "27.0", state: .booted)
    }

    func isKeyboardVisible() async throws -> Bool {
        visible
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        let all = [
            ElementInfo(
                id: "Done", label: "Done", type: .button, frame: Rect(x: 340, y: 60, width: 50, height: 30)
            ),
            ElementInfo(
                id: "Search", label: "search", type: .button, frame: Rect(x: 329, y: 828, width: 108, height: 56)
            )
        ]
        return all.filter { element in selector.label.map { $0 == element.label } ?? true }
    }

    func tap(at point: Point) async throws {
        actions.append("tap \(point.x),\(point.y)")
        visible = false
    }

    func pressBack() async throws {
        actions.append("back")
        visible = false
    }

    func pressKey(_: KeyboardKey, modifiers _: Set<KeyModifier>) async throws {
        actions.append("hardware return")
        visible = false
    }
}
