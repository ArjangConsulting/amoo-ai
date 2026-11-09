import AmooCore
import Foundation
import MCP
@testable import MCPServer
import XCTest

/// Expectations on `tap_element` and the foreground check on `press_back`.
extension TapChecksTests {
    func testPressBackThatLeavesTheAppSaysSo() async {
        let driver = TapCheckDriver(
            target: Self.addButton, hierarchy: screen(), foregrounds: ["com.jot", "com.android.launcher"]
        )
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "press_back", arguments: [:])
        XCTAssertFalse(result.isError, result.content)
        let fields = result.structuredContent?.objectValue
        XCTAssertEqual(fields?["left_app"]?.boolValue, true)
        XCTAssertEqual(fields?["foreground_bundle_id"]?.stringValue, "com.android.launcher")
        XCTAssertTrue(result.content.contains("leaves the app"), result.content)
    }

    func testPressBackWithinTheAppReportsNoChange() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen())
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "press_back", arguments: [:])
        XCTAssertEqual(result.structuredContent?.objectValue?["left_app"]?.boolValue, false)
        XCTAssertEqual(result.content, "Pressed back")
    }

    func testExpectAbsentOnAnElementAlreadyGoneIsInconclusive() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen(), missingIDs: ["spinner"])
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add", "expect_id": "spinner", "expect_absent": "true"]
        )
        XCTAssertFalse(result.isError, result.content)
        let fields = result.structuredContent?.objectValue
        XCTAssertEqual(fields?["expectation_status"]?.stringValue, "already_satisfied")
        XCTAssertNil(fields?["expected_effect_met"])
        XCTAssertTrue(result.content.contains("Inconclusive"), result.content)
        let waits = await driver.waits
        XCTAssertTrue(waits.isEmpty, "waiting on an element that was never there proves nothing")
    }

    func testExpectAbsentOnAPresentElementReportsMet() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen())
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add", "expect_id": "spinner", "expect_absent": "true"]
        )
        XCTAssertEqual(result.structuredContent?.objectValue?["expectation_status"]?.stringValue, "met")
    }
}
