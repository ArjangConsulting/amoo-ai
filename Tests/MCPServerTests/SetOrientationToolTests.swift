import AmooCore
@testable import MCPServer
import XCTest

final class SetOrientationToolTests: XCTestCase {
    func testRotatesAndReportsTheReadBack() async {
        let driver = MockDriver()
        let result = await DriverToolExecutor(driver: driver)
            .execute(toolName: "set_orientation", arguments: ["orientation": "landscape_left"])

        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.content, "Orientation set to landscape_left")
        let calls = await driver.calls
        XCTAssertEqual(calls, ["orientation:landscape_left"])
    }

    /// A device that did not turn must not read as success.
    func testDeviceThatStaysPutIsAnError() async {
        let driver = MockDriver()
        await driver.stubReportedOrientation(.portrait)
        let result = await DriverToolExecutor(driver: driver)
            .execute(toolName: "set_orientation", arguments: ["orientation": "landscape_right"])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("device reports portrait"), result.content)
    }

    func testRejectsUnknownOrientationWithoutTouchingTheDevice() async {
        let driver = MockDriver()
        let result = await DriverToolExecutor(driver: driver)
            .execute(toolName: "set_orientation", arguments: ["orientation": "sideways"])

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("portrait_upside_down"), result.content)
        let calls = await driver.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testMissingOrientationNamesTheChoices() async {
        let result = await DriverToolExecutor(driver: MockDriver())
            .execute(toolName: "set_orientation", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("landscape_left"), result.content)
    }
}
