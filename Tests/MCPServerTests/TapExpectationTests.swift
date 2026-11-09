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

    func testPressBackUsesTheForegroundTheCompanionReports() async {
        let driver = TapCheckDriver(
            target: Self.addButton, hierarchy: screen(), reportedForeground: "com.android.launcher"
        )
        let result = await DriverToolExecutor(driver: driver).execute(toolName: "press_back", arguments: [:])
        XCTAssertEqual(result.structuredContent?.objectValue?["left_app"]?.boolValue, true, result.content)
        let reads = await driver.currentAppReads
        XCTAssertEqual(reads, 1, "only the read before the press; the companion reported the one after")
    }

    func testTapUsesTheForegroundTheCompanionReports() async {
        let driver = TapCheckDriver(target: Self.addButton, hierarchy: screen(), reportedForeground: "com.apple.siri")
        let result = await DriverToolExecutor(driver: driver).execute(
            toolName: "tap_element", arguments: ["id": "add", "check_effect": "false"]
        )
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["foreground_changed"]?.boolValue, true)
        XCTAssertEqual(result.structuredContent?.objectValue?["foreground_bundle_id"]?.stringValue, "com.apple.siri")
        let reads = await driver.currentAppReads
        XCTAssertEqual(reads, 1, "only the read before the tap")
    }

    func testCompactTapOmitsFieldsThatHoldTheirDefault() async throws {
        let unlabeled = ElementInfo(id: "add", label: "", type: .button, frame: Self.addButton.frame)
        let driver = TapCheckDriver(target: unlabeled, hierarchy: screen())
        let executor = DriverToolExecutor(driver: driver)
        let arguments = ["id": "add", "check_effect": "false", "check_hittable": "false"]
        let fullResult = await executor.execute(toolName: "tap_element", arguments: arguments)
        let compactResult = await executor.execute(
            toolName: "tap_element", arguments: arguments.merging(["response_mode": "compact"]) { $1 }
        )
        let full = try XCTUnwrap(fullResult.structuredContent?.objectValue)
        let compact = try XCTUnwrap(compactResult.structuredContent?.objectValue)
        XCTAssertEqual(full["postcondition_verified"], .bool(false))
        XCTAssertEqual(full["hittability_checked"], .bool(false))
        XCTAssertEqual(full["element_label"], .string(""))
        for key in ["postcondition_verified", "hittability_checked", "element_label"] {
            XCTAssertNil(compact[key], "\(key) holds its default and is omitted in compact mode")
        }
        XCTAssertEqual(compact["outcome_status"], .string("dispatched"))
        XCTAssertEqual(compact["element_id"], .string("add"))
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
