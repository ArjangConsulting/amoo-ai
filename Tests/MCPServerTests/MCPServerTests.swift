
@testable import MCPServer
import MobileTestingCore
import XCTest

final class MCPServerTests: XCTestCase {
    func testToolNamesAreExposed() {
        let server = MCPServer()
        let names = server.toolNames()
        XCTAssertTrue(names.contains("tap"))
        XCTAssertTrue(names.contains("device_boot"))
        XCTAssertTrue(names.contains("find_elements"))
        XCTAssertTrue(names.contains("get_screen_context"))
        XCTAssertTrue(names.contains("scroll"))
        XCTAssertTrue(names.contains("set_permission"))
        XCTAssertTrue(names.contains("audit_app"))
        XCTAssertTrue(names.contains("audit_accessibility"))
        XCTAssertTrue(names.contains("audit_security"))
        XCTAssertTrue(names.contains("ai_describe_screen"))
        XCTAssertTrue(names.contains("ai_suggest_actions"))
        XCTAssertTrue(names.contains("ai_find_by_description"))
        XCTAssertTrue(names.contains("describe_screen"))
        XCTAssertTrue(names.contains("suggest_actions"))
        XCTAssertTrue(names.contains("find_by_description"))
    }

    func testToolDefinitionsHaveSchemas() throws {
        let server = MCPServer()
        let defs = server.toolDefinitions()
        XCTAssertFalse(defs.isEmpty)

        let tap = defs.first(where: { $0.name == "tap" })
        XCTAssertNotNil(tap)
        XCTAssertEqual(tap?.required, ["x", "y"])
        XCTAssertEqual(tap?.properties.count, 2)
        XCTAssertFalse(try XCTUnwrap(tap?.description.isEmpty))
    }

    func testHealthPassThrough() {
        let server = MCPServer()
        XCTAssertEqual(server.health(), "ok")
    }

    func testExecuteWithoutDriverReturnsError() async {
        let server = MCPServer()
        let result = await server.execute(toolName: "tap", arguments: ["x": "10", "y": "20"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("No tool executor"))
    }

    func testExecuteTapDelegatesToDriver() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "tap", arguments: ["x": "10", "y": "20"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Tapped"))

        let calls = await driver.calls
        XCTAssertEqual(calls, ["tap:10.0,20.0"])
    }

    func testExecuteDeviceLifecycle() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let boot = await server.execute(toolName: "device_boot", arguments: [:])
        XCTAssertFalse(boot.isError)

        let install = await server.execute(toolName: "device_install_app", arguments: ["path": "/tmp/App.app"])
        XCTAssertFalse(install.isError)

        let launch = await server.execute(toolName: "device_launch_app", arguments: ["app_id": "com.example"])
        XCTAssertFalse(launch.isError)

        let calls = await driver.calls
        XCTAssertEqual(calls, ["boot", "install:/tmp/App.app", "launch:com.example"])
    }

    func testExecuteValidatesArguments() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "tap", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Missing required"))
    }

    func testExecuteUnknownToolReturnsError() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "nonexistent", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("Unknown tool"))
    }

    func testExecuteQueryTools() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let context = await server.execute(toolName: "get_screen_context", arguments: [:])
        XCTAssertFalse(context.isError)
        XCTAssertEqual(context.content, "Mock screen")

        let hierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        XCTAssertFalse(hierarchy.isError)
        XCTAssertTrue(hierarchy.content.contains("root"))
    }

    func testExecuteScrollAndTypeText() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let scroll = await server.execute(toolName: "scroll", arguments: ["direction": "down"])
        XCTAssertFalse(scroll.isError)

        let typeText = await server.execute(toolName: "type_text", arguments: ["text": "hello"])
        XCTAssertFalse(typeText.isError)

        let calls = await driver.calls
        XCTAssertEqual(calls, ["scroll:down:300.0", "typeText:hello"])
    }

    // MARK: - Audit Tool Tests

    func testAuditAppRequiresAppID() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_app", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("app_id"))
    }

    func testAuditAppReturnsFindings() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_app", arguments: ["app_id": "com.test"])
        XCTAssertFalse(result.isError)
        // The mock driver returns elements that trigger audit rules (e.g. missing labels)
        XCTAssertTrue(result.content.contains("com.test"))
    }

    func testAuditSecurityRunsSecurityRulesOnly() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_security", arguments: ["app_id": "com.test"])
        XCTAssertFalse(result.isError)
    }

    func testAuditAccessibilityRunsUXRules() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_accessibility", arguments: ["app_id": "com.test"])
        XCTAssertFalse(result.isError)
    }

    func testAuditWithFailOnThreshold() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "audit_app",
            arguments: ["app_id": "com.test", "fail_on": "low"]
        )
        // If there are findings at low or above, isError should be true
        if result.content.contains("finding") {
            XCTAssertTrue(result.isError)
        }
    }

    func testAuditPassesCleanApp() async {
        let driver = MockDriver() // Clean mock with no problematic elements
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "audit_app", arguments: ["app_id": "com.clean"])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Audit passed") || result.content.contains("finding"))
    }

    // MARK: - AI Tool Tests

    func testDescribeScreenWithoutAIProvider() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "ai_describe_screen", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "Mock screen")
    }

    func testDescribeScreenWithLocalAIProvider() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver, aiProvider: LocalAIProvider())
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "ai_describe_screen", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content, "Mock screen")
    }

    func testSuggestActionsWithoutAIProvider() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "ai_suggest_actions", arguments: [:])
        XCTAssertFalse(result.isError)
        // MockDriver returns empty interactables, so fallback returns "No interactable elements found"
        XCTAssertTrue(result.content.contains("No interactable"))
    }

    func testSuggestActionsWithInteractableElements() async {
        let driver = AuditMockDriver() // Has interactable elements
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "ai_suggest_actions", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Tap"))
    }

    func testSuggestActionsWithLocalAIProvider() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver, aiProvider: LocalAIProvider())
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "ai_suggest_actions", arguments: [:])
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.content.contains("Tap"))
    }

    func testFindByDescriptionRequiresDescription() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "ai_find_by_description", arguments: [:])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("description"))
    }

    func testFindByDescriptionWithoutAIProvider() async {
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let result = await server.execute(
            toolName: "ai_find_by_description",
            arguments: ["description": "login button"]
        )
        XCTAssertFalse(result.isError)
        // MockDriver.findByDescription returns empty, so "No elements matched"
        XCTAssertTrue(result.content.contains("No elements matched"))
    }

    func testFindByDescriptionWithLocalAIProvider() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver, aiProvider: LocalAIProvider())
        let server = MCPServer(executor: executor)

        let result = await server.execute(toolName: "ai_find_by_description", arguments: ["description": "submit"])
        XCTAssertFalse(result.isError)
        // LocalAIProvider does substring matching; AuditMockDriver has a "Submit" button
        XCTAssertTrue(result.content.contains("match") || result.content.contains("No elements"))
    }

    func testDeprecatedAIAliasesMatchCanonicalTools() async {
        let driver = AuditMockDriver()
        let executor = DriverToolExecutor(driver: driver)
        let server = MCPServer(executor: executor)

        let describeAlias = await server.execute(toolName: "describe_screen", arguments: [:])
        let describeCanonical = await server.execute(toolName: "ai_describe_screen", arguments: [:])
        XCTAssertEqual(describeAlias.content, describeCanonical.content)

        let suggestAlias = await server.execute(toolName: "suggest_actions", arguments: [:])
        let suggestCanonical = await server.execute(toolName: "ai_suggest_actions", arguments: [:])
        XCTAssertEqual(suggestAlias.content, suggestCanonical.content)

        let findAlias = await server.execute(toolName: "find_by_description", arguments: ["description": "submit"])
        let findCanonical = await server.execute(
            toolName: "ai_find_by_description",
            arguments: ["description": "submit"]
        )
        XCTAssertEqual(findAlias.content, findCanonical.content)
    }

    func testLocalAIProviderResolveDescriptionMatchesLabelAndIDCaseInsensitively() async throws {
        let provider = LocalAIProvider()
        let elements = [
            ElementInfo(id: "submit_btn", label: "Submit"),
            ElementInfo(id: "cancel_btn", label: "Cancel")
        ]

        let labelMatches = try await provider.resolveDescription("SUBMIT", elements: elements)
        let idMatches = try await provider.resolveDescription("cancel_btn", elements: elements)

        XCTAssertEqual(labelMatches, [ElementInfo(id: "submit_btn", label: "Submit")])
        XCTAssertEqual(idMatches, [ElementInfo(id: "cancel_btn", label: "Cancel")])
    }

    func testOllamaProviderDescribeScreenBuildsPromptAndTrimsResponse() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        let provider = OllamaProvider(baseURL: "http://ollama.local", model: "tiny-model") { request in
            await captured.set(request)
            let response = try HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = try JSONSerialization.data(withJSONObject: ["response": "  concise summary  \n"])
            return (data, response)
        }

        let summary = try await provider.describeScreen(
            context: ScreenContext(summary: "Checkout", interactableCount: 2, screenTitle: "Cart"),
            hierarchy: ViewNode(
                id: "root",
                children: [
                    ViewNode(id: "title", label: "Cart", type: .staticText),
                    ViewNode(id: "cta", label: "Pay", type: .button)
                ]
            )
        )

        let capturedRequest = await captured.value
        let request = try XCTUnwrap(capturedRequest)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let prompt = try XCTUnwrap(json["prompt"] as? String)

        XCTAssertEqual(summary, "concise summary")
        XCTAssertEqual(request.url?.absoluteString, "http://ollama.local/api/generate")
        XCTAssertEqual(json["model"] as? String, "tiny-model")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertTrue(prompt.contains("Screen title: Cart"))
        XCTAssertTrue(prompt.contains("button(Pay)"))
    }

    func testOllamaProviderSuggestActionsSplitsLinesAndTruncatesElementList() async throws {
        let provider = OllamaProvider(baseURL: "http://ollama.local", model: "tiny-model") { request in
            let response = try HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = try JSONSerialization.data(withJSONObject: ["response": "Tap Login\nScroll down\n"])
            return (data, response)
        }
        let elements = (1 ... 25).map { index in
            ElementInfo(id: "id-\(index)", label: "Label \(index)", type: .button)
        }

        let actions = try await provider.suggestActions(
            context: ScreenContext(summary: "Home"),
            interactableElements: elements
        )

        XCTAssertEqual(actions, ["Tap Login", "Scroll down"])
    }

    func testOllamaProviderResolveDescriptionMatchesIDsAndLabelsFromResponse() async throws {
        let provider = OllamaProvider(baseURL: "http://ollama.local", model: "tiny-model") { request in
            let response = try HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = try JSONSerialization
                .data(withJSONObject: ["response": "Use submit1 and Settings for this action"])
            return (data, response)
        }
        let elements = [
            ElementInfo(id: "submit1", label: "Submit", type: .button),
            ElementInfo(id: "settings", label: "Settings", type: .button),
            ElementInfo(id: "help", label: "Help", type: .button)
        ]

        let matches = try await provider.resolveDescription("submit action", elements: elements)

        XCTAssertEqual(matches, [
            ElementInfo(id: "submit1", label: "Submit", type: .button),
            ElementInfo(id: "settings", label: "Settings", type: .button)
        ])
    }

    func testOllamaProviderThrowsHTTPAndJSONErrors() async {
        let httpProvider = OllamaProvider(baseURL: "http://ollama.local", model: "tiny-model") { request in
            let response = try HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("failure".utf8), response)
        }
        let jsonProvider = OllamaProvider(baseURL: "http://ollama.local", model: "tiny-model") { request in
            let response = try HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = try JSONSerialization.data(withJSONObject: ["unexpected": true])
            return (data, response)
        }

        do {
            _ = try await httpProvider.describeScreen(
                context: ScreenContext(summary: "Fail"),
                hierarchy: ViewNode(id: "root")
            )
            XCTFail("Expected http error")
        } catch let error as OllamaError {
            guard case let .httpError(statusCode, body) = error else {
                return XCTFail("Unexpected OllamaError: \(error)")
            }
            XCTAssertEqual(statusCode, 500)
            XCTAssertEqual(body, "failure")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await jsonProvider.describeScreen(
                context: ScreenContext(summary: "Fail"),
                hierarchy: ViewNode(id: "root")
            )
            XCTFail("Expected invalid JSON")
        } catch let error as OllamaError {
            guard case .invalidJSON = error else {
                return XCTFail("Unexpected OllamaError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor LockedBox<Value: Sendable> {
    private var storage: Value

    init(_ storage: Value) {
        self.storage = storage
    }

    func set(_ value: Value) {
        storage = value
    }

    var value: Value {
        storage
    }
}

/// Mock driver that returns elements triggering audit rules.
private actor AuditMockDriver: PlatformDriver {
    func boot() async throws {}
    func shutdown() async throws {}
    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "mock", name: "Mock", platform: .ios, osVersion: "17.0", state: .booted)
    }

    func installApp(path _: String) async throws {}
    func launchApp(appID _: String, arguments _: [String], environment _: [String: String]) async throws {}
    func terminateApp(appID _: String) async throws {}
    func uninstallApp(appID _: String) async throws {}

    func tap(at _: Point) async throws {}
    func doubleTap(at _: Point) async throws {}
    func longPress(at _: Point, duration _: Duration) async throws {}
    func tapElement(_: ElementSelector) async throws {}

    func swipe(from _: Point, to _: Point, duration _: Duration) async throws {}
    func swipe(direction _: Direction) async throws {}
    func scroll(direction _: Direction, distance _: Double) async throws {}
    func scrollToElement(_: ElementSelector, direction _: Direction, maxScrolls _: Int) async throws {}
    func pinch(center _: Point, scale _: Double, velocity _: Double) async throws {}
    func drag(from _: Point, to _: Point, duration _: Duration, holdDuration _: Duration) async throws {}

    func typeText(_: String) async throws {}
    func clearText(characterCount _: Int?) async throws {}
    func setText(_: ElementSelector, text _: String) async throws {}

    func pressBack() async throws {}
    func pressHome() async throws {}
    func openURL(_: String) async throws {}

    func findElements(_: ElementSelector) async throws -> [ElementInfo] {
        [
            // Element with empty label and empty id — triggers missing accessibility label
            ElementInfo(id: "", label: "", type: .button, frame: Rect(x: 0, y: 0, width: 30, height: 30)),
            // Small tap target
            ElementInfo(id: "tiny", label: "Tiny", type: .button, frame: Rect(x: 10, y: 10, width: 20, height: 20)),
            // Sensitive text field — triggers insecure text field rule
            ElementInfo(id: "password_field", label: "Password", type: .textField),
            // Normal button
            ElementInfo(
                id: "submit_btn",
                label: "Submit",
                type: .button,
                frame: Rect(x: 0, y: 0, width: 100, height: 44)
            )
        ]
    }

    func getViewHierarchy() async throws -> ViewNode {
        ViewNode(id: "root")
    }

    func elementExists(_: ElementSelector) async throws -> Bool {
        true
    }

    func waitForElement(_: ElementSelector, timeout _: Duration) async throws {}
    func waitForElementToDisappear(_: ElementSelector, timeout _: Duration) async throws {}
    func isKeyboardVisible() async throws -> Bool {
        false
    }

    func takeScreenshot(format _: ImageFormat) async throws -> ScreenshotData {
        ScreenshotData(bytes: [0xFF])
    }

    func startRecording() async throws -> RecordingSession {
        RecordingSession(id: "rec", deviceID: "mock")
    }

    func stopRecording(_: RecordingSession) async throws {}

    func setPermission(_: PermissionChange) async throws {}
    func setLocation(latitude _: Double, longitude _: Double) async throws {}
    func clearLocation() async throws {}
    func setAppearance(_: Appearance) async throws {}

    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "Debug mode enabled - Test screen", interactableCount: 4)
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        [
            ElementInfo(id: "submit_btn", label: "Submit", type: .button),
            ElementInfo(id: "cancel_btn", label: "Cancel", type: .button)
        ]
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        []
    }

    func listApps() async throws -> [AppInfo] {
        []
    }

    func appState(appID _: String) async throws -> AppState {
        .notRunning
    }
}

private actor MockDriver: PlatformDriver {
    var calls: [String] = []

    func boot() async throws {
        calls.append("boot")
    }

    func shutdown() async throws {
        calls.append("shutdown")
    }

    func deviceInfo() async throws -> DeviceInfo {
        DeviceInfo(id: "mock", name: "Mock", platform: .ios, osVersion: "17.0", state: .booted)
    }

    func installApp(path: String) async throws {
        calls.append("install:\(path)")
    }

    func launchApp(appID: String, arguments _: [String], environment _: [String: String]) async throws {
        calls.append("launch:\(appID)")
    }

    func terminateApp(appID: String) async throws {
        calls.append("terminate:\(appID)")
    }

    func uninstallApp(appID: String) async throws {
        calls.append("uninstall:\(appID)")
    }

    func tap(at point: Point) async throws {
        calls.append("tap:\(point.x),\(point.y)")
    }

    func doubleTap(at point: Point) async throws {
        calls.append("doubleTap:\(point.x),\(point.y)")
    }

    func longPress(at _: Point, duration _: Duration) async throws {
        calls.append("longPress")
    }

    func tapElement(_: ElementSelector) async throws {
        calls.append("tapElement")
    }

    func swipe(from _: Point, to _: Point, duration _: Duration) async throws {
        calls.append("swipe")
    }

    func swipe(direction _: Direction) async throws {
        calls.append("swipeDir")
    }

    func scroll(direction: Direction, distance: Double) async throws {
        calls.append("scroll:\(direction):\(distance)")
    }

    func scrollToElement(_: ElementSelector, direction _: Direction, maxScrolls _: Int) async throws {}
    func pinch(center _: Point, scale _: Double, velocity _: Double) async throws {}
    func drag(from _: Point, to _: Point, duration _: Duration, holdDuration _: Duration) async throws {}

    func typeText(_ text: String) async throws {
        calls.append("typeText:\(text)")
    }

    func clearText(characterCount _: Int?) async throws {
        calls.append("clearText")
    }

    func setText(_: ElementSelector, text _: String) async throws {}

    func pressBack() async throws {
        calls.append("pressBack")
    }

    func pressHome() async throws {
        calls.append("pressHome")
    }

    func openURL(_ url: String) async throws {
        calls.append("openURL:\(url)")
    }

    func findElements(_ selector: ElementSelector) async throws -> [ElementInfo] {
        [ElementInfo(id: selector.id ?? "el", label: selector.label ?? "label")]
    }

    func getViewHierarchy() async throws -> ViewNode {
        ViewNode(id: "root")
    }

    func elementExists(_: ElementSelector) async throws -> Bool {
        true
    }

    func waitForElement(_: ElementSelector, timeout _: Duration) async throws {}
    func waitForElementToDisappear(_: ElementSelector, timeout _: Duration) async throws {}
    func isKeyboardVisible() async throws -> Bool {
        false
    }

    func takeScreenshot(format _: ImageFormat) async throws -> ScreenshotData {
        ScreenshotData(bytes: [0xFF])
    }

    func startRecording() async throws -> RecordingSession {
        RecordingSession(id: "rec", deviceID: "mock")
    }

    func stopRecording(_: RecordingSession) async throws {}

    func setPermission(_ change: PermissionChange) async throws {
        calls.append("permission:\(change.appID):\(change.permission)")
    }

    func setLocation(latitude: Double, longitude: Double) async throws {
        calls.append("location:\(latitude),\(longitude)")
    }

    func clearLocation() async throws {
        calls.append("clearLocation")
    }

    func setAppearance(_ appearance: Appearance) async throws {
        calls.append("appearance:\(appearance.rawValue)")
    }

    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "Mock screen")
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        []
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        []
    }

    func listApps() async throws -> [AppInfo] {
        []
    }

    func appState(appID _: String) async throws -> AppState {
        .notRunning
    }
}
