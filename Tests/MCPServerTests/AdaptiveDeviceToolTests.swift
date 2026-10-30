import AmooCore
@testable import MCPServer
import XCTest

final class AdaptiveDeviceToolTests: XCTestCase {
    func testPostureReportsVerifiedReadBack() async {
        let driver = AdaptiveToolDriver()
        let result = await DriverToolExecutor(driver: driver)
            .execute(toolName: "set_posture", arguments: ["posture": "half_opened"])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["posture"]?.stringValue, "half_opened")
        XCTAssertEqual(result.structuredContent?.objectValue?["verified"]?.boolValue, true)
        let calls = await driver.calls
        XCTAssertEqual(calls, ["posture:half_opened"])
    }

    func testDisplayReportsMeasuredGeometry() async {
        let result = await DriverToolExecutor(driver: AdaptiveToolDriver())
            .execute(toolName: "set_display_preset", arguments: ["preset": "tablet"])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertEqual(result.structuredContent?.objectValue?["width_pixels"]?.intValue, 1920)
        XCTAssertEqual(result.structuredContent?.objectValue?["density_dpi"]?.intValue, 240)
    }

    func testInvalidAndMissingValuesNeverDispatch() async {
        let driver = AdaptiveToolDriver()
        let executor = DriverToolExecutor(driver: driver)
        for (tool, arguments) in [
            ("set_posture", ["posture": "sideways"]), ("set_posture", [:]),
            ("set_display_preset", ["preset": "watch"]), ("set_display_preset", [:])
        ] {
            let result = await executor.execute(toolName: tool, arguments: arguments)
            XCTAssertTrue(result.isError, result.content)
        }
        let calls = await driver.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testIgnoredPostureIsNotReportedAsSuccess() async {
        let driver = AdaptiveToolDriver(posture: .opened)
        let result = await DriverToolExecutor(driver: driver)
            .execute(toolName: "set_posture", arguments: ["posture": "closed"])
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.structuredContent?.objectValue?["code"]?.stringValue, "postcondition_failed")
    }

    func testUnsupportedDriverFailsExplicitly() async {
        let result = await DriverToolExecutor(driver: UnsupportedAdaptiveDriver())
            .execute(toolName: "set_posture", arguments: ["posture": "closed"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Android foldable emulator"), result.content)
    }

    func testCatalogEnumeratesValuesAndMarksBothToolsAsMutations() throws {
        let tools = MCPServer().toolDefinitions()
        let posture = try XCTUnwrap(tools.first { $0.name == "set_posture" })
        XCTAssertEqual(posture.properties["posture"]?.values, ["closed", "half_opened", "opened"])
        XCTAssertEqual(posture.readOnly, false)
        let display = try XCTUnwrap(tools.first { $0.name == "set_display_preset" })
        XCTAssertEqual(display.properties["preset"]?.values, ["phone", "unfolded", "tablet"])
        XCTAssertEqual(display.readOnly, false)
    }
}

private actor UnsupportedAdaptiveDriver: PlatformDriver {}

private actor AdaptiveToolDriver: PlatformDriver {
    var calls: [String] = []
    let posture: DevicePosture?

    init(posture: DevicePosture? = nil) {
        self.posture = posture
    }

    func setPosture(_ posture: DevicePosture) async throws -> DevicePosture {
        calls.append("posture:\(posture.rawValue)")
        return self.posture ?? posture
    }

    func setDisplayPreset(_ preset: DisplayPreset) async throws -> DeviceDisplayConfiguration {
        calls.append("display:\(preset.rawValue)")
        return DeviceDisplayConfiguration(widthPixels: 1920, heightPixels: 1200, densityDPI: 240)
    }
}
