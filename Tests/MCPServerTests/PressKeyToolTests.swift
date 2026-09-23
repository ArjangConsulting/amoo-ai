import AmooCore
@testable import MCPServer
import XCTest

final class PressKeyToolTests: XCTestCase {
    func testPressesKeyWithModifiers() async {
        let driver = MockDriver()
        let result = await DriverToolExecutor(driver: driver)
            .execute(toolName: "press_key", arguments: ["key": "right_arrow", "modifiers": "Shift, command"])

        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.content, "Pressed command+shift+right_arrow")
        let calls = await driver.calls
        XCTAssertEqual(calls, ["key:command+shift+right_arrow"])
    }

    func testSingleCharacterNeedsNoModifiers() async {
        let driver = MockDriver()
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "press_key", arguments: ["key": "t"])
        XCTAssertEqual(result.content, "Pressed t")
    }

    func testUnknownKeyOrModifierNeverReachesTheDevice() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let badKey = await executor.execute(toolName: "press_key", arguments: ["key": "arrow"])
        let badModifier = await executor.execute(
            toolName: "press_key", arguments: ["key": "a", "modifiers": "hyper"]
        )
        let missing = await executor.execute(toolName: "press_key", arguments: [:])

        XCTAssertTrue(badKey.isError)
        XCTAssertTrue(badKey.content.contains("left_arrow"), badKey.content)
        XCTAssertTrue(badModifier.isError)
        XCTAssertTrue(badModifier.content.contains("control"), badModifier.content)
        XCTAssertTrue(missing.isError)
        let calls = await driver.calls
        XCTAssertTrue(calls.isEmpty)
    }
}
