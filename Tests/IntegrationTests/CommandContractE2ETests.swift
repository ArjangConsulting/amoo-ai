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
            return ProcessInfo.processInfo.environment["E2E_DEVICE_ID"] ?? "booted"
        case .android:
            return ProcessInfo.processInfo.environment["E2E_DEVICE_ID"]
        }
    }

    private static var fixtureAppID: String {
        ProcessInfo.processInfo.environment["E2E_APP_ID"] ?? (platform == .ios ? "com.mobiletesting.companion" : "com.manman.companion")
    }

    override func setUp() async throws {
        guard Self.isPortOpen(Self.companionPort) else {
            throw XCTSkip("Companion not running on port \(Self.companionPort). Use the platform e2e script.")
        }
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

        let launchResult = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])
        XCTAssertFalse(launchResult.isError)

        let titleResult = await server.execute(toolName: "find_elements", arguments: ["label": "Fixture Home"])
        XCTAssertFalse(titleResult.isError)
        XCTAssertTrue(titleResult.content.contains("Fixture Home"))

        let hierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        XCTAssertFalse(hierarchy.isError)
        XCTAssertTrue(hierarchy.content.contains("Fixture") || hierarchy.content.contains("com.apple.springboard") || hierarchy.content.contains("com.android.launcher"))

        let screenContext = await server.execute(toolName: "get_screen_context", arguments: [:])
        XCTAssertFalse(screenContext.isError)
        XCTAssertFalse(screenContext.content.isEmpty)
    }

    func testNavigateToDetailsAndScroll() async throws {
        let server = try makeServer()
        _ = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])

        let openDetails = await server.execute(toolName: "tap_element", arguments: ["label": "Open Details"])
        XCTAssertFalse(openDetails.isError)

        let beforeScroll = await server.execute(toolName: "find_elements", arguments: ["contains_text": "Details tail marker"])
        XCTAssertFalse(beforeScroll.isError)

        let scroll = await server.execute(toolName: "scroll", arguments: ["direction": "down", "distance": "500"])
        XCTAssertFalse(scroll.isError)

        let afterScroll = await server.execute(toolName: "find_elements", arguments: ["contains_text": "Details tail marker"])
        XCTAssertFalse(afterScroll.isError)
    }

    func testTextEntryAndClearing() async throws {
        let server = try makeServer()
        _ = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])

        let openText = await server.execute(toolName: "tap_element", arguments: ["label": "Open Text Input"])
        XCTAssertFalse(openText.isError)
        let typeText = await server.execute(toolName: "type_text", arguments: ["text": "contract text"])
        XCTAssertFalse(typeText.isError)

        let valueAfterTyping = await server.execute(toolName: "find_elements", arguments: ["contains_text": "contract text"])
        XCTAssertFalse(valueAfterTyping.isError)
        XCTAssertTrue(valueAfterTyping.content.contains("contract text"))

        let clearText = await server.execute(toolName: "clear_text", arguments: [:])
        XCTAssertFalse(clearText.isError)
    }

    func testGestureCommands() async throws {
        let server = try makeServer()
        _ = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])
        let openGesture = await server.execute(toolName: "tap_element", arguments: ["label": "Open Gesture Lab"])
        XCTAssertFalse(openGesture.isError)

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
        let longPress = await server.execute(toolName: "long_press", arguments: ["x": centerX, "y": centerY, "duration_ms": "800"])
        XCTAssertFalse(longPress.isError)
        let swipe = await server.execute(toolName: "swipe", arguments: ["from_x": centerX, "from_y": centerY, "to_x": centerX, "to_y": "120", "duration_ms": "300"])
        XCTAssertFalse(swipe.isError)
    }

    func testPressHomeAndRelaunch() async throws {
        let server = try makeServer()
        _ = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])

        let homeResult = await server.execute(toolName: "press_home", arguments: [:])
        XCTAssertFalse(homeResult.isError)

        let hierarchy = try await currentDriver().getViewHierarchy()
        switch Self.platform {
        case .ios:
            XCTAssertTrue(hierarchy.label.contains("springboard") || hierarchy.id.contains("springboard") || !hierarchy.children.isEmpty)
        case .android:
            XCTAssertNotEqual(hierarchy.label, Self.fixtureAppID)
        }

        let relaunch = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])
        XCTAssertFalse(relaunch.isError)
    }

    func testOpenURLAndScreenshot() async throws {
        let server = try makeServer()
        _ = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])

        let deepLink = "mobile-testing://deep-link?source=contract"
        let openURL = await server.execute(toolName: "open_url", arguments: ["url": deepLink])
        XCTAssertFalse(openURL.isError)

        let deepLinkResult = await server.execute(toolName: "find_elements", arguments: ["contains_text": "mobile-testing://"])
        XCTAssertFalse(deepLinkResult.isError)

        let screenshot = await server.execute(toolName: "take_screenshot", arguments: [:])
        XCTAssertFalse(screenshot.isError)
        XCTAssertTrue(screenshot.content.contains("bytes"))
    }

    func testAICanonicalNamesAndAliases() async throws {
        let server = try makeServer()
        _ = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])

        for canonical in CommandCoverageMatrix.aiToolNames {
            let result = await server.execute(toolName: canonical, arguments: canonical == "ai_find_by_description" ? ["description": "Fixture Home"] : [:])
            XCTAssertFalse(result.isError, "Expected \(canonical) to succeed: \(result.content)")
            XCTAssertFalse(result.content.isEmpty)
        }

        for (alias, canonical) in CommandCoverageMatrix.deprecatedAIAliases {
            let aliasResult = await server.execute(toolName: alias, arguments: canonical == "ai_find_by_description" ? ["description": "Fixture Home"] : [:])
            let canonicalResult = await server.execute(toolName: canonical, arguments: canonical == "ai_find_by_description" ? ["description": "Fixture Home"] : [:])
            XCTAssertEqual(aliasResult.content, canonicalResult.content)
        }
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
        return MCPServer(executor: DriverToolExecutor(driver: driver))
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
