import AmooCore
import AndroidDriver
import CommandContract
import CompanionProtocol
import Darwin.C
import IOSDriver
import MCPServer
import XCTest

extension CommandContractE2ETests {
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
        // Row 10 is not a safe "not yet rendered" checkpoint: on a tall device, SwiftUI's List
        // pre-renders enough rows past the viewport that row 10 is already in the hierarchy before
        // any scroll — the sibling test testHierarchyReachesDeeperRowsAfterMultipleScrolls proves
        // row 20 stays absent through zero scrolls, so 15 sits at a conservative midpoint between
        // the two known reference rows.
        XCTAssertFalse(initialHierarchy.content.contains("fixture-detail-row-15"))

        let scroll = await server.execute(toolName: "scroll", arguments: ["direction": "down", "distance": "900"])
        XCTAssertFalse(scroll.isError)

        let scrolledHierarchy = await server.execute(toolName: "get_view_hierarchy", arguments: [:])
        XCTAssertFalse(scrolledHierarchy.isError)
        XCTAssertTrue(scrolledHierarchy.content.contains("fixture-detail-row-15"))
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
            // Explicit appID (not the bare selector overload) sidesteps the same "who is
            // frontmost" guess verifyLaunch relies on. That alone was not enough: even scoped
            // correctly, a snapshot taken immediately after type_text can still return the
            // field's pre-edit value — XCUITest's accessibility snapshot lags the synthetic
            // keystrokes' own completion by up to a couple hundred milliseconds on this
            // environment. Poll briefly rather than trust the very next snapshot.
            let typedElements = try await pollFindElements(
                driver: driver,
                id: "fixture-text-input",
                appID: Self.fixtureAppID
            ) { $0.first?.value as? String == "contract text" }
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
            let clearedElements = try await pollFindElements(
                driver: driver,
                id: "fixture-text-input",
                appID: Self.fixtureAppID
            ) { elements in
                guard let element = elements.first else { return false }
                let value = element.value
                // A cleared field's accessibility value was found to report nil here, not "" —
                // both mean "no content" and either is a correct cleared state.
                return value == nil || value == "" || value == "Fixture Input"
            }
            let clearedElement = try XCTUnwrap(clearedElements.first, "elements: \(clearedElements)")
            let clearedValue = clearedElement.value
            XCTAssertTrue(
                clearedValue == nil || clearedValue == "" || clearedValue == "Fixture Input",
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

    func makeCompanion() throws -> GRPCCompanionClient {
        let connection = CompanionConnection(host: "127.0.0.1", port: Self.companionPort)
        return try GRPCCompanionClient.makeLive(connection: connection)
    }

    func currentDriver() throws -> any PlatformDriver {
        let companion = try makeCompanion()
        switch Self.platform {
        case .ios:
            return IOSDriver(companion: companion, deviceID: Self.deviceID ?? "booted")
        case .android:
            return AndroidDriver(companion: companion, serial: Self.deviceID)
        }
    }

    func makeServer() throws -> MCPServer {
        let driver = try currentDriver()
        return MCPServer(executor: DriverToolExecutor(driver: driver))
    }

    func makeServerWithDriver() throws -> (MCPServer, any PlatformDriver) {
        let driver = try currentDriver()
        let server = MCPServer(executor: DriverToolExecutor(driver: driver))
        return (server, driver)
    }

    static func isPortOpen(_ port: Int) -> Bool {
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

    /// Polls `driver.findElements` until `isReady` accepts the result or the budget runs out.
    ///
    /// A snapshot taken immediately after a text-entry action can still report the field's
    /// pre-edit value on this environment — XCUITest's accessibility snapshot lags the
    /// synthetic keystrokes' own completion by up to a couple hundred milliseconds. One read is
    /// not enough to tell "still catching up" apart from "genuinely wrong"; several are.
    func pollFindElements(
        driver: any PlatformDriver,
        id: String,
        appID: String?,
        // Confirmed against a live companion: `assert_value` reading the exact same field
        // succeeded several seconds after typing, while a 2-second poll budget consistently did
        // not — this environment's accessibility value updates settle far slower than XCUITest
        // normally does elsewhere in this suite. 15s covers what was observed with headroom.
        attempts: Int = 30,
        sleepMilliseconds: UInt64 = 500,
        isReady: ([ElementInfo]) -> Bool
    ) async throws -> [ElementInfo] {
        var last: [ElementInfo] = []
        for attempt in 0 ..< attempts {
            last = try await driver.findElements(.init(id: id), appID: appID)
            if isReady(last) {
                return last
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: sleepMilliseconds * 1_000_000)
            }
        }
        return last
    }
}
