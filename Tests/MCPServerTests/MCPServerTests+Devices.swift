import AmooCore
import Foundation
import MCP
@testable import MCPServer
import TestSession
import XCTest

extension MCPServerTests {
    // MARK: - Device discovery & app inventory

    func testListDevicesReturnsBootstrapperResults() async throws {
        let stack = makeSessionStack()
        let driver = stack.defaultDriver
        let manager = stack.manager
        let bootstrapper = stack.bootstrapper
        await bootstrapper.setDevices([
            DeviceInfo(id: "udid-1", name: "iPhone 15", platform: .ios, osVersion: "17.0", state: .booted),
            DeviceInfo(id: "emulator-5554", name: "Pixel 7", platform: .android, osVersion: "14", state: .booted)
        ])
        let executor = DriverToolExecutor(driver: driver, sessionManager: manager)
        let server = MCPServer(executor: executor, sessionManager: manager)

        let result = await server.execute(toolName: "list_devices", arguments: [:])
        XCTAssertFalse(result.isError)
        let devices = try XCTUnwrap(result.structuredContent?.objectValue?["devices"]?.arrayValue)
        XCTAssertEqual(devices.count, 2)
    }

    func testListAppsCallsDriverListApps() async throws {
        let driver = AppListMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "list_apps", arguments: [:])
        XCTAssertFalse(result.isError)
        let apps = try XCTUnwrap(result.structuredContent?.objectValue?["apps"]?.arrayValue)
        XCTAssertEqual(apps.count, 2)
    }

    // MARK: - device_launch_app args & env

    func testDeviceLaunchAppPassesLaunchArgsAndEnvironment() async {
        let driver = LaunchTrackingDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        _ = await server.execute(
            toolName: "device_launch_app",
            arguments: [
                "app_id": "com.example",
                "launch_args": "-ui_test,fast",
                "environment": "STAGE=test,VERBOSE=1"
            ]
        )

        let calls = await driver.launchCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.appID, "com.example")
        XCTAssertEqual(calls.first?.arguments, ["-ui_test", "fast"])
        XCTAssertEqual(calls.first?.environment, ["STAGE": "test", "VERBOSE": "1"])
    }

    // MARK: - Intent tools

    func testFillFieldCallsSetText() async {
        let driver = SetTextTrackingDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "fill_field",
            arguments: ["field_description": "Email", "value": "user@test.com"]
        )
        XCTAssertFalse(result.isError, result.content)
        let calls = await driver.setTextCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.selector.id, "email-field")
        XCTAssertEqual(calls.first?.text, "user@test.com")
        XCTAssertFalse(result.content.contains("user@test.com"))
    }

    /// A field that already held text would otherwise satisfy the "value is non-empty" fallback
    /// meant for masked secure fields, reporting a set that never happened as verified.
    func testSetTextRejectsAFieldWhoseValueNeverChanged() async {
        let driver = StubbornFieldDriver(existingValue: "old@test.com")
        let executor = DriverToolExecutor(driver: driver)

        let result = await executor.execute(
            toolName: "set_text",
            arguments: ["id": "email-field", "value": "new@test.com"]
        )

        XCTAssertTrue(result.isError, result.content)
        XCTAssertFalse(result.content.contains("new@test.com"))
    }

    /// The frontmost app during the launch animation is still the previous one. Reading it once,
    /// immediately, made a healthy launch look like a failure.
    func testLaunchAppVerificationPollsPastTheLaunchAnimation() async {
        let driver = SettlingLaunchDriver(settleAfterReads: 2, targetAppID: "com.example")
        let executor = DriverToolExecutor(driver: driver)

        let result = await executor.execute(
            toolName: "device_launch_app",
            arguments: ["app_id": "com.example", "timeout_ms": "3000"]
        )

        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(result.content.contains("verified=true"), result.content)
    }

    func testLaunchAppReportsAMismatchThatNeverSettles() async {
        let driver = SettlingLaunchDriver(settleAfterReads: .max, targetAppID: "com.example")
        let executor = DriverToolExecutor(driver: driver)

        let result = await executor.execute(
            toolName: "device_launch_app",
            arguments: ["app_id": "com.example", "timeout_ms": "1"]
        )

        XCTAssertTrue(result.isError, result.content)
        XCTAssertTrue(result.content.contains("com.other"), result.content)
    }

    func testDeterministicElementAssertions() async {
        let enabledDriver = NavigationMockDriver(elements: [
            ElementInfo(id: "email", label: "Email", value: "ready", type: .textField)
        ])
        let enabledExecutor = DriverToolExecutor(driver: enabledDriver)

        let enabled = await enabledExecutor.execute(
            toolName: "assert_enabled",
            arguments: ["id": "email", "timeout_ms": "1"]
        )
        let value = await enabledExecutor.execute(
            toolName: "assert_value",
            arguments: ["id": "email", "expected": "ready", "timeout_ms": "1"]
        )
        let absent = await DriverToolExecutor(driver: NavigationMockDriver(elements: [])).execute(
            toolName: "assert_absent",
            arguments: ["id": "missing", "timeout_ms": "1"]
        )

        XCTAssertFalse(enabled.isError, enabled.content)
        XCTAssertFalse(value.isError, value.content)
        XCTAssertFalse(absent.isError, absent.content)
    }

    func testAssertScreenChangedUsesContextToken() async throws {
        let driver = NavigationMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let baseline = await executor.execute(toolName: "get_screen_context", arguments: [:])
        let token = try XCTUnwrap(baseline.structuredContent?.objectValue?["screen_token"]?.stringValue)

        try await driver.tapElement(.init(id: "submit_btn"))
        let result = await executor.execute(
            toolName: "assert_screen_changed",
            arguments: ["from_token": token, "timeout_ms": "10"]
        )

        XCTAssertFalse(result.isError, result.content)
    }

    func testNavigateToTapsMatchingElement() async throws {
        let driver = NavigationMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "navigate_to",
            arguments: ["description": "Submit", "timeout_ms": "500"]
        )
        XCTAssertFalse(result.isError, result.content)
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(structured["navigated"]?.boolValue, true)
        let tapped = await driver.tappedSelectors
        XCTAssertEqual(tapped.count, 1)
    }

    func testNavigateToReturnsFailureWhenNoMatch() async throws {
        let driver = NavigationMockDriver(elements: [], summary: "Home")
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "navigate_to",
            arguments: ["description": "Pluto", "timeout_ms": "200"]
        )
        XCTAssertTrue(result.isError)
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(structured["navigated"]?.boolValue, false)
        XCTAssertEqual(structured["reason"]?.stringValue, "no_match")
    }

    func testAssertVisibleSucceedsWhenElementPresent() async throws {
        let driver = NavigationMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "assert_visible",
            arguments: ["description": "Submit", "timeout_ms": "200"]
        )
        XCTAssertFalse(result.isError, result.content)
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(structured["passed"]?.boolValue, true)
    }

    func testAssertVisibleTimesOut() async throws {
        let driver = NavigationMockDriver(elements: [], summary: "Home")
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "assert_visible",
            arguments: ["description": "Nope", "timeout_ms": "200"]
        )
        XCTAssertTrue(result.isError)
        let structured = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(structured["passed"]?.boolValue, false)
    }

    // MARK: - Screenshot

    func testTakeScreenshotReturnsImageContentBlock() async throws {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "take_screenshot", arguments: [:])
        XCTAssertFalse(result.isError, result.content)

        let image = try XCTUnwrap(result.image, "take_screenshot must return an image content block")
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertFalse(image.data.isEmpty)

        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(fields["format"]?.stringValue, "png")
        XCTAssertEqual(fields["byte_count"]?.intValue, 1)

        // The MCP result should carry both a text and an image content item.
        let mcp = result.mcpResult()
        XCTAssertEqual(mcp.content.count, 2)
    }

    func testTakeScreenshotJPEGAcceptsJpgAlias() async throws {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "take_screenshot", arguments: ["format": "jpg"])
        XCTAssertFalse(result.isError, result.content)
        let image = try XCTUnwrap(result.image)
        XCTAssertEqual(image.mimeType, "image/jpeg")
        XCTAssertEqual(result.structuredContent?.objectValue?["format"]?.stringValue, "jpeg")
    }

    func testTakeScreenshotWritesToOutputPath() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let path = NSTemporaryDirectory() + "amoo-shot-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = await server.execute(toolName: "take_screenshot", arguments: ["output": path])
        XCTAssertFalse(result.isError, result.content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(result.structuredContent?.objectValue?["saved_path"]?.stringValue, path)
        XCTAssertTrue(result.content.contains("saved to"))
    }

    func testTakeScreenshotWriteFailureKeepsRequiredStructuredFields() async throws {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let path = NSTemporaryDirectory() + "amoo-missing-\(UUID().uuidString)/shot.png"
        let result = await server.execute(toolName: "take_screenshot", arguments: ["output": path])

        XCTAssertTrue(result.isError)
        // The declared outputSchema requires byte_count and format even on error.
        let fields = try XCTUnwrap(result.structuredContent?.objectValue)
        XCTAssertEqual(fields["byte_count"]?.intValue, 1)
        XCTAssertEqual(fields["format"]?.stringValue, "png")
        XCTAssertNil(fields["saved_path"])
    }

    // MARK: - Helpers

    struct SessionStack {
        let defaultDriver: MockDriver
        let manager: SessionManager
        let bootstrapper: MockSessionBootstrapper
    }

    func makeSessionStack() -> SessionStack {
        let defaultDriver = MockDriver()
        let bootstrapper = MockSessionBootstrapper()
        let manager = SessionManager(bootstrapper: bootstrapper, idGenerator: { UUID().uuidString })
        return SessionStack(defaultDriver: defaultDriver, manager: manager, bootstrapper: bootstrapper)
    }
}
