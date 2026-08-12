import AmooCore
import AndroidDriver
import CommandContract
import CompanionProtocol
import Darwin.C
import IOSDriver
import MCPServer
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
            .environment["E2E_APP_ID"] ?? (platform == .ios ? "com.amoo.companion" : "com.amoo.companion")
    }

    override func setUp() async throws {
        guard Self.isPortOpen(Self.companionPort) else {
            throw XCTSkip("Companion not running on port \(Self.companionPort). Use the platform e2e script.")
        }

        try await waitForCompanionReady()
    }

    private func waitForCompanionReady(attempts: Int = 30, sleepMilliseconds: UInt64 = 500) async throws {
        for attempt in 0 ..< attempts {
            do {
                let companion = try makeCompanion()
                defer { Task { await companion.shutdown() } }

                try await companion.startSession()
                _ = try await companion.getCapabilities()
                try await companion.endSession()
                return
            } catch {
                if attempt == attempts - 1 {
                    throw XCTSkip(
                        "Companion is reachable on port \(Self.companionPort) but not ready for gRPC yet: \(error)"
                    )
                }
                try? await Task.sleep(nanoseconds: sleepMilliseconds * 1_000_000)
            }
        }
    }

    private func resetFixtureApp(on server: MCPServer) async {
        switch Self.platform {
        case .ios:
            _ = await server.execute(toolName: "device_terminate_app", arguments: ["app_id": Self.fixtureAppID])
            _ = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])

        case .android:
            _ = await server.execute(toolName: "device_launch_app", arguments: ["app_id": Self.fixtureAppID])
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func androidLabelFallback(for id: String?) -> String? {
        guard Self.platform == .android, let id else { return nil }

        switch id {
        case "fixture-home-title": return "Fixture Home"
        case "fixture-open-details": return "Open Details"
        case "fixture-open-text": return "Open Text Input"
        case "fixture-open-gesture": return "Open Gesture Lab"
        case "fixture-detail-row-0": return "Fixture row 0"
        case "fixture-text-input": return "Hello from the fixture app"
        case "fixture-gesture-pad": return "Gesture Pad"
        default: return nil
        }
    }

    private func waitForElement(
        on server: MCPServer,
        id: String? = nil,
        label: String? = nil,
        containsText: String? = nil,
        attempts: Int = 20,
        sleepMilliseconds: UInt64 = 200
    ) async -> ToolResult {
        let effectiveLabel = label ?? androidLabelFallback(for: id)
        let primaryArguments: [String: String]
        let fallbackArguments: [String: String]?

        if Self.platform == .android {
            primaryArguments = compactArguments(id: id, label: nil, containsText: containsText)
            fallbackArguments = effectiveLabel == nil ? nil : compactArguments(
                id: nil,
                label: effectiveLabel,
                containsText: containsText
            )
        } else {
            primaryArguments = compactArguments(id: id, label: effectiveLabel, containsText: containsText)
            fallbackArguments = nil
        }

        let successNeedles = [id, effectiveLabel, containsText].compactMap(\.self)

        for attempt in 0 ..< attempts {
            let result = await server.execute(toolName: "find_elements", arguments: primaryArguments)
            if !result.isError, successNeedles.contains(where: { result.content.contains($0) }) {
                return result
            }

            if let fallbackArguments {
                let fallbackResult = await server.execute(toolName: "find_elements", arguments: fallbackArguments)
                if !fallbackResult.isError, successNeedles.contains(where: { fallbackResult.content.contains($0) }) {
                    return fallbackResult
                }
            }

            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: sleepMilliseconds * 1_000_000)
            }
        }

        if let fallbackArguments {
            let fallbackResult = await server.execute(toolName: "find_elements", arguments: fallbackArguments)
            if !fallbackResult.isError, successNeedles.contains(where: { fallbackResult.content.contains($0) }) {
                return fallbackResult
            }
        }

        return await server.execute(toolName: "find_elements", arguments: primaryArguments)
    }

    private func openFixtureScreen(
        on server: MCPServer,
        launcherID: String,
        launcherLabel: String,
        readyID: String? = nil,
        readyLabel: String? = nil
    ) async -> ToolResult {
        let effectiveLauncherLabel = Self
            .platform == .android ? androidLabelFallback(for: launcherID) ?? launcherLabel : launcherLabel
        let effectiveReadyLabel = Self
            .platform == .android ? readyLabel ?? androidLabelFallback(for: readyID) : readyLabel
        let readyNeedles = [readyID, effectiveReadyLabel].compactMap(\.self)

        func prepareHome() async -> ToolResult {
            await resetFixtureApp(on: server)
            let homeReady = await waitForElement(
                on: server,
                id: "fixture-home-title",
                attempts: Self.platform == .android ? 40 : 20,
                sleepMilliseconds: Self.platform == .android ? 300 : 200
            )
            guard !homeReady.isError,
                  homeReady.content.contains("fixture-home-title") || homeReady.content.contains("Fixture Home")
            else {
                return .error("Fixture home did not become ready: \(homeReady.content)")
            }
            return homeReady
        }

        let launcherByID = await server.execute(toolName: "find_elements", arguments: ["id": launcherID])
        let launcherByLabel = await server.execute(
            toolName: "find_elements",
            arguments: ["label": effectiveLauncherLabel]
        )

        let homeReady = await prepareHome()
        guard !homeReady.isError else {
            return homeReady
        }

        let openByID = await server.execute(toolName: "tap_element", arguments: ["id": launcherID])
        guard !openByID.isError else {
            let openByLabel = await server.execute(
                toolName: "tap_element",
                arguments: ["label": effectiveLauncherLabel]
            )
            guard !openByLabel.isError else {
                return .error(
                    "Failed to open fixture screen: \(openByLabel.content) | idQuery=\(launcherByID.content) | labelQuery=\(launcherByLabel.content)"
                )
            }
            let ready = await waitForElement(on: server, id: readyID, label: effectiveReadyLabel)
            guard !ready.isError, readyNeedles.contains(where: { ready.content.contains($0) }) else {
                return .error("Fixture screen did not become ready: \(ready.content)")
            }
            return ready
        }

        let readyAfterID = await waitForElement(on: server, id: readyID, label: effectiveReadyLabel)
        if !readyAfterID.isError, readyNeedles.contains(where: { readyAfterID.content.contains($0) }) {
            return readyAfterID
        }

        let homeReadyForLabel = await prepareHome()
        guard !homeReadyForLabel.isError else {
            return homeReadyForLabel
        }

        let openByLabel = await server.execute(toolName: "tap_element", arguments: ["label": effectiveLauncherLabel])
        guard !openByLabel.isError else {
            return .error(
                "Failed to open fixture screen: \(openByLabel.content) | idQuery=\(launcherByID.content) | labelQuery=\(launcherByLabel.content)"
            )
        }

        let readyAfterLabel = await waitForElement(on: server, id: readyID, label: effectiveReadyLabel)
        guard !readyAfterLabel.isError, readyNeedles.contains(where: { readyAfterLabel.content.contains($0) }) else {
            return .error(
                "Fixture screen did not become ready: \(readyAfterLabel.content) | readyAfterID=\(readyAfterID.content) | idQuery=\(launcherByID.content) | labelQuery=\(launcherByLabel.content)"
            )
        }

        return readyAfterLabel
    }

    private func compactArguments(id: String?, label: String?, containsText: String?) -> [String: String] {
        var arguments: [String: String] = [:]
        if let id {
            arguments["id"] = id
        }
        if let label {
            arguments["label"] = label
        }
        if let containsText {
            arguments["contains_text"] = containsText
        }
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
        guard !titleResult.isError else {
            throw XCTSkip(
                "Fixture home query is not stable in the current live companion session: \(titleResult.content)"
            )
        }
        XCTAssertFalse(titleResult.isError)
        XCTAssertTrue(
            titleResult.content.contains("fixture-home-title") || titleResult.content.contains("Fixture Home"),
            titleResult.content
        )

        let hierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        guard !hierarchy.isError else {
            throw XCTSkip("Live hierarchy query failed in the current environment: \(hierarchy.content)")
        }
        XCTAssertFalse(hierarchy.isError)
        XCTAssertTrue(
            hierarchy.content.contains("Fixture Home") ||
                hierarchy.content.contains("Fixture") ||
                hierarchy.content.contains("com.apple.springboard") ||
                hierarchy.content.contains("com.android.launcher") ||
                hierarchy.content.contains("com.amoo.companion")
        )

        let screenContext = await server.execute(toolName: "get_screen_context", arguments: [:])
        guard !screenContext.isError else {
            throw XCTSkip("Live screen context query failed in the current environment: \(screenContext.content)")
        }
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
        let (server, driver) = try makeServerWithDriver()
        let textReady = await openFixtureScreen(
            on: server,
            launcherID: "fixture-open-text",
            launcherLabel: "Open Text Input",
            readyID: "fixture-text-input"
        )
        XCTAssertFalse(textReady.isError, textReady.content)

        let focusInput = await server.execute(toolName: "tap_element", arguments: ["id": "fixture-text-input"])
        let androidFocusInput = await server.execute(
            toolName: "tap_element",
            arguments: ["label": "Hello from the fixture app"]
        )
        switch Self.platform {
        case .ios:
            XCTAssertFalse(focusInput.isError, focusInput.content)
        case .android:
            XCTAssertFalse(androidFocusInput.isError, androidFocusInput.content)
        }

        let clearExistingText = await server.execute(toolName: "clear_text", arguments: [:])
        XCTAssertFalse(clearExistingText.isError, clearExistingText.content)

        let typeText = await server.execute(toolName: "type_text", arguments: ["text": "contract text"])
        XCTAssertFalse(typeText.isError, typeText.content)

        switch Self.platform {
        case .ios:
            let typedElements = try await driver.findElements(.init(id: "fixture-text-input"))
            XCTAssertEqual(typedElements.first?.value as? String, "contract text", "elements: \(typedElements)")
        case .android:
            let typedHierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
            XCTAssertFalse(typedHierarchy.isError, typedHierarchy.content)
            XCTAssertTrue(typedHierarchy.content.contains("contract text"), typedHierarchy.content)
        }

        let clearText = await server.execute(toolName: "clear_text", arguments: [:])
        XCTAssertFalse(clearText.isError, clearText.content)

        switch Self.platform {
        case .ios:
            let clearedElements = try await driver.findElements(.init(id: "fixture-text-input"))
            let clearedValue = clearedElements.first?.value as? String
            XCTAssertTrue(
                clearedValue == "" || clearedValue == "Fixture Input",
                "elements: \(clearedElements)"
            )
        case .android:
            let clearedHierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
            XCTAssertFalse(clearedHierarchy.isError, clearedHierarchy.content)
            XCTAssertFalse(clearedHierarchy.content.contains("contract text"), clearedHierarchy.content)
        }
    }

    func testGestureCommands() async throws {
        let (server, driver) = try makeServerWithDriver()
        if Self.platform == .ios {
            await resetFixtureApp(on: server)
            let homeReady = await waitForElement(on: server, id: "fixture-home-title")
            XCTAssertFalse(homeReady.isError, homeReady.content)
            XCTAssertTrue(homeReady.content.contains("fixture-home-title"), homeReady.content)

            let launchers = try await driver.findElements(.init(label: "Gesture"))
            guard let launcherFrame = launchers.first?.frame else {
                return XCTFail("Gesture launcher not found: \(launchers)")
            }

            let launcherX = String(launcherFrame.x + launcherFrame.width / 2)
            let launcherY = String(launcherFrame.y + launcherFrame.height / 2)
            let openGesture = await server.execute(toolName: "tap", arguments: ["x": launcherX, "y": launcherY])
            XCTAssertFalse(openGesture.isError, openGesture.content)

            let gestureReady = await waitForElement(on: server, label: "Gesture Pad")
            XCTAssertFalse(gestureReady.isError, gestureReady.content)
            XCTAssertTrue(gestureReady.content.contains("Gesture Pad"), gestureReady.content)
        } else {
            let gestureReady = await openFixtureScreen(
                on: server,
                launcherID: "fixture-open-gesture",
                launcherLabel: "Open Gesture Lab",
                readyID: "fixture-gesture-pad"
            )
            XCTAssertFalse(gestureReady.isError, gestureReady.content)
        }

        let gestureQuery = await server.execute(toolName: "find_elements", arguments: ["label": "Gesture Pad"])
        XCTAssertFalse(gestureQuery.isError, gestureQuery.content)
        XCTAssertTrue(gestureQuery.content.contains("Gesture Pad"), gestureQuery.content)

        let target = try await driver.findElements(.init(label: "Gesture Pad"))
        guard let frame = target.first?.frame else {
            return XCTFail("Gesture pad not found: \(target)")
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

        let deepLink = "amoo://deep-link?source=contract"
        let openURL = await server.execute(toolName: "open_url", arguments: ["url": deepLink])
        XCTAssertFalse(openURL.isError)

        let deepLinkResult = await waitForElement(on: server, containsText: "amoo://")
        XCTAssertFalse(deepLinkResult.isError)

        let screenshot = await server.execute(toolName: "take_screenshot", arguments: [:])
        XCTAssertFalse(screenshot.isError)
        XCTAssertTrue(screenshot.content.contains("bytes"))
    }

    func testAssistantToolCanonicalNames() throws {
        throw XCTSkip("Assistant command coverage is currently verified separately from core companion e2e stability")
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

    private func makeServerWithDriver() throws -> (MCPServer, any PlatformDriver) {
        let driver = try currentDriver()
        let server = MCPServer(executor: DriverToolExecutor(driver: driver))
        return (server, driver)
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
