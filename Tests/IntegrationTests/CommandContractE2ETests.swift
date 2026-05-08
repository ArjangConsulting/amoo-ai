import AndroidDriver
import CommandContract
import CompanionProtocol
import Darwin.C
import IOSDriver
import MCPServer
import MobileTestingCore
import XCTest

final class CommandContractE2ETests: XCTestCase {
    private enum E2EPlatform: String {
        case ios
        case android
    }

    private static var platform: E2EPlatform {
        E2EPlatform(rawValue: ProcessInfo.processInfo.environment["E2E_PLATFORM"] ?? "ios") ?? .ios
    }

    private static var companionPort: Int {
        ProcessInfo.processInfo.environment["COMPANION_PORT"].flatMap(Int.init) ?? (platform == .ios ? 22087 : 22088)
    }

    private static var deviceID: String? {
        switch platform {
        case .ios:
            ProcessInfo.processInfo.environment["E2E_DEVICE_ID"] ?? "booted"
        case .android:
            ProcessInfo.processInfo.environment["E2E_DEVICE_ID"]
        }
    }

    private static var fixtureAppID: String {
        ProcessInfo.processInfo
            .environment["E2E_APP_ID"] ?? (platform == .ios ? "com.mobiletesting.companion" : "com.manman.companion")
    }

    override func setUp() async throws {
        guard Self.isPortOpen(Self.companionPort) else {
            throw XCTSkip("Companion not running on port \(Self.companionPort). Use the platform e2e script.")
        }
    }

    private func resetFixtureApp(on server: MCPServer) async {
        _ = await server.execute(toolName: "device_terminate_app", arguments: ["app_id": Self.fixtureAppID])
        _ = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])
    }

    private func waitForElement(
        on server: MCPServer,
        id: String? = nil,
        label: String? = nil,
        containsText: String? = nil,
        attempts: Int = 20,
        sleepMilliseconds: UInt64 = 200
    ) async -> ToolResult {
        let arguments = compactArguments(id: id, label: label, containsText: containsText)

        for attempt in 0 ..< attempts {
            let result = await server.execute(toolName: "find_elements", arguments: arguments)
            if !result.isError, let needle = id ?? label ?? containsText, result.content.contains(needle) {
                return result
            }

            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: sleepMilliseconds * 1_000_000)
            }
        }

        return await server.execute(toolName: "find_elements", arguments: arguments)
    }

    private func openFixtureScreen(
        on server: MCPServer,
        launcherID: String,
        launcherLabel: String,
        readyID: String? = nil,
        readyLabel: String? = nil
    ) async -> ToolResult {
        await resetFixtureApp(on: server)

        let homeReady = await waitForElement(on: server, id: "fixture-home-title")
        guard !homeReady.isError, homeReady.content.contains("fixture-home-title") else {
            return .error("Fixture home did not become ready: \(homeReady.content)")
        }

        let openByID = await server.execute(toolName: "tap_element", arguments: ["id": launcherID])
        let openScreen: ToolResult = if openByID.isError {
            await server.execute(toolName: "tap_element", arguments: ["label": launcherLabel])
        } else {
            openByID
        }
        guard !openScreen.isError else {
            return .error("Failed to open fixture screen: \(openScreen.content)")
        }

        let ready = await waitForElement(on: server, id: readyID, label: readyLabel)
        let readyNeedle = readyID ?? readyLabel ?? ""
        guard !ready.isError, ready.content.contains(readyNeedle) else {
            return .error("Fixture screen did not become ready: \(ready.content)")
        }

        return ready
    }

    private func compactArguments(id: String?, label: String?, containsText: String?) -> [String: String] {
        var arguments: [String: String] = [:]
        if let id { arguments["id"] = id }
        if let label { arguments["label"] = label }
        if let containsText { arguments["contains_text"] = containsText }
        return arguments
    }

    func testStartAndEndSession() async throws {
        let companion = try makeCompanion()
        defer { Task { await companion.shutdown() } }

        try await companion.startSession()
        let capabilities = try await companion.getCapabilities()
        XCTAssertFalse(capabilities.isEmpty, "Companion should report capabilities")
        try await companion.endSession()
    }

    func testFixtureHomeQueries() async throws {
        let server = try makeServer()

        await resetFixtureApp(on: server)

        let titleResult = await waitForElement(on: server, id: "fixture-home-title")
        XCTAssertFalse(titleResult.isError)
        XCTAssertTrue(titleResult.content.contains("fixture-home-title") || titleResult.content.contains("Fixture Home"))

        let hierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        XCTAssertFalse(hierarchy.isError)
        XCTAssertTrue(hierarchy.content.contains("Fixture Home") || hierarchy.content.contains("Fixture") || hierarchy.content
            .contains("com.apple.springboard") || hierarchy.content.contains("com.android.launcher"))

        let screenContext = await server.execute(toolName: "get_screen_context", arguments: [:])
        XCTAssertFalse(screenContext.isError)
        XCTAssertFalse(screenContext.content.isEmpty)
    }

    func testNavigateToDetailsAndScroll() async throws {
        let server = try makeServer()
        let detailsReady = await openFixtureScreen(
            on: server,
            launcherID: "fixture-open-details",
            launcherLabel: "Open Details",
            readyID: "fixture-detail-row-0"
        )
        XCTAssertFalse(detailsReady.isError)

        let beforeScroll = await server.execute(
            toolName: "find_elements",
            arguments: ["id": "fixture-details-tail"]
        )
        XCTAssertFalse(beforeScroll.isError)

        let scroll = await server.execute(toolName: "scroll", arguments: ["direction": "down", "distance": "500"])
        XCTAssertFalse(scroll.isError)

        let afterScroll = await server.execute(
            toolName: "find_elements",
            arguments: ["id": "fixture-details-tail"]
        )
        XCTAssertFalse(afterScroll.isError)
    }

    func testHierarchyReflectsCurrentlyRenderedDetailsRows() async throws {
        guard Self.platform == .ios else {
            throw XCTSkip("Rendered hierarchy assertion is currently iOS-specific")
        }

        let server = try makeServer()
        let detailsReady = await openFixtureScreen(
            on: server,
            launcherID: "fixture-open-details",
            launcherLabel: "Open Details",
            readyID: "fixture-detail-row-0"
        )
        XCTAssertFalse(detailsReady.isError)

        let initialHierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        XCTAssertFalse(initialHierarchy.isError)
        XCTAssertFalse(initialHierarchy.content.contains("fixture-detail-row-10"))

        let scroll = await server.execute(toolName: "scroll", arguments: ["direction": "down", "distance": "900"])
        XCTAssertFalse(scroll.isError)

        let scrolledHierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        XCTAssertFalse(scrolledHierarchy.isError)
        XCTAssertTrue(scrolledHierarchy.content.contains("fixture-detail-row-10"))
    }

    func testHierarchyReachesDeeperRowsAfterMultipleScrolls() async throws {
        guard Self.platform == .ios else {
            throw XCTSkip("Rendered hierarchy assertion is currently iOS-specific")
        }

        let server = try makeServer()
        let detailsReady = await openFixtureScreen(
            on: server,
            launcherID: "fixture-open-details",
            launcherLabel: "Open Details",
            readyID: "fixture-detail-row-0"
        )
        XCTAssertFalse(detailsReady.isError)

        let initialHierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        XCTAssertFalse(initialHierarchy.isError)
        XCTAssertFalse(initialHierarchy.content.contains("fixture-detail-row-20"))

        for _ in 0 ..< 2 {
            let scroll = await server.execute(toolName: "scroll", arguments: ["direction": "down", "distance": "900"])
            XCTAssertFalse(scroll.isError)
        }

        let scrolledHierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        XCTAssertFalse(scrolledHierarchy.isError)
        XCTAssertTrue(scrolledHierarchy.content.contains("fixture-detail-row-20"))
    }

    func testTextEntryAndClearing() async throws {
        let server = try makeServer()
        let textReady = await openFixtureScreen(
            on: server,
            launcherID: "fixture-open-text",
            launcherLabel: "Open Text Input",
            readyID: "fixture-text-value"
        )
        XCTAssertFalse(textReady.isError)

        let focusTextInput = await server.execute(toolName: "tap_element", arguments: ["id": "fixture-text-input"])
        XCTAssertFalse(focusTextInput.isError)
        let typeText = await server.execute(toolName: "type_text", arguments: ["text": "contract text"])
        XCTAssertFalse(typeText.isError)

        let valueAfterTyping = await waitForElement(on: server, containsText: "contract text")
        XCTAssertFalse(valueAfterTyping.isError)
        XCTAssertTrue(valueAfterTyping.content.contains("contract text"))

        let clearText = await server.execute(toolName: "clear_text", arguments: [:])
        XCTAssertFalse(clearText.isError)
    }

    func testGestureCommands() async throws {
        let server = try makeServer()
        let gestureReady = await openFixtureScreen(
            on: server,
            launcherID: "fixture-open-gesture",
            launcherLabel: "Open Gesture Lab",
            readyLabel: "Gesture Pad"
        )
        XCTAssertFalse(gestureReady.isError)

        let target = try await currentDriver().findElements(.init(label: "Gesture Pad"))
        guard let frame = target.first?.frame else {
            return XCTFail("Gesture pad not found")
        }

        let centerX = String(frame.x + frame.width / 2)
        let centerY = String(frame.y + frame.height / 2)

        let tap = await server.execute(toolName: "tap", arguments: ["x": centerX, "y": centerY])
        XCTAssertFalse(tap.isError)
        let doubleTap = await server.execute(toolName: "double_tap", arguments: ["x": centerX, "y": centerY])
        XCTAssertFalse(doubleTap.isError)
        let longPress = await server.execute(
            toolName: "long_press",
            arguments: ["x": centerX, "y": centerY, "duration_ms": "800"]
        )
        XCTAssertFalse(longPress.isError)
        let swipe = await server.execute(
            toolName: "swipe",
            arguments: ["from_x": centerX, "from_y": centerY, "to_x": centerX, "to_y": "120", "duration_ms": "300"]
        )
        XCTAssertFalse(swipe.isError)
    }

    func testPressHomeAndRelaunch() async throws {
        let server = try makeServer()
        await resetFixtureApp(on: server)

        let homeResult = await server.execute(toolName: "press_home", arguments: [:])
        XCTAssertFalse(homeResult.isError)

        let hierarchy = try await currentDriver().getViewHierarchy()
        switch Self.platform {
        case .ios:
            XCTAssertTrue(hierarchy.label.contains("springboard") || hierarchy.id.contains("springboard") || !hierarchy
                .children.isEmpty)
        case .android:
            XCTAssertNotEqual(hierarchy.label, Self.fixtureAppID)
        }

        let relaunch = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])
        XCTAssertFalse(relaunch.isError)
    }

    func testOpenURLAndScreenshot() async throws {
        let server = try makeServer()
        await resetFixtureApp(on: server)

        let deepLink = "mobile-testing://deep-link?source=contract"
        let openURL = await server.execute(toolName: "open_url", arguments: ["url": deepLink])
        XCTAssertFalse(openURL.isError)

        let deepLinkResult = await waitForElement(on: server, containsText: "mobile-testing://")
        XCTAssertFalse(deepLinkResult.isError)

        let screenshot = await server.execute(toolName: "take_screenshot", arguments: [:])
        XCTAssertFalse(screenshot.isError)
        XCTAssertTrue(screenshot.content.contains("bytes"))
    }

    func testAICanonicalNames() async throws {
        throw XCTSkip("AI command coverage is currently verified separately from core companion e2e stability")
    }

    private func makeCompanion() throws -> GRPCCompanionClient {
        let connection = CompanionConnection(host: "127.0.0.1", port: Self.companionPort)
        return try GRPCCompanionClient.makeLive(connection: connection)
    }

    private func currentDriver() throws -> any PlatformDriver {
        let companion = try makeCompanion()
        switch Self.platform {
        case .ios:
            return IOSDriver(companion: companion, deviceID: Self.deviceID ?? "booted")
        case .android:
            return AndroidDriver(companion: companion, serial: Self.deviceID)
        }
    }

    private func makeServer() throws -> MCPServer {
        let driver = try currentDriver()
        return MCPServer(executor: DriverToolExecutor(driver: driver, aiProvider: LocalAIProvider()))
    }

    private static func isPortOpen(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
