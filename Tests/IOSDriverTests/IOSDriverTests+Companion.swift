import AmooCore
import CompanionProtocol
import Foundation
import IOSDriver
import ProcessRunner
import XCTest

extension IOSDriverTests {
    func testDeviceInfoFallsBackForInvalidJSON() async throws {
        let simctl = MockSimctlRunner()
        await simctl.setDevicesJSON("not-json")
        let driver = IOSDriver(companion: MockCompanionClient(), simctl: simctl, deviceID: "custom-device")

        let info = try await driver.deviceInfo()

        XCTAssertEqual(info.id, "custom-device")
        XCTAssertEqual(info.name, "custom-device")
        XCTAssertEqual(info.osVersion, "unknown")
        XCTAssertEqual(info.state, .unknown)
    }

    func testListAppsParsesJSONAndPlistFallback() async throws {
        let jsonSimctl = MockSimctlRunner()
        await jsonSimctl.setAppListOutput(
            """
            [
              {
                "CFBundleIdentifier": "com.example.json",
                "CFBundleDisplayName": "JSON App",
                "CFBundleShortVersionString": "2.0"
              }
            ]
            """
        )
        let plistSimctl = MockSimctlRunner()
        await plistSimctl.setAppListOutput(
            """
            <plist>
            <dict>
              <key>CFBundleIdentifier</key>
              <string>com.example.plist</string>
            </dict>
            </plist>
            """
        )

        let jsonApps = try await IOSDriver(companion: MockCompanionClient(), simctl: jsonSimctl).listApps()
        let plistApps = try await IOSDriver(companion: MockCompanionClient(), simctl: plistSimctl).listApps()

        XCTAssertEqual(jsonApps, [AppInfo(appID: "com.example.json", name: "JSON App", version: "2.0")])
        XCTAssertEqual(plistApps, [AppInfo(appID: "com.example.plist")])
    }

    func testDelegatesRemainingCompanionAndSimctlOperations() async throws {
        let simctl = MockSimctlRunner()
        let companion = MockCompanionClient()
        let driver = IOSDriver(companion: companion, simctl: simctl)

        try await driver.doubleTap(at: Point(x: 1, y: 2))
        try await driver.longPress(at: Point(x: 3, y: 4), duration: .defaultLongPress)
        try await driver.swipe(from: Point(x: 0, y: 0), to: Point(x: 10, y: 20), duration: .defaultSwipe)
        try await driver.scroll(direction: .down, distance: 44)
        try await driver.typeText("hello")
        try await driver.clearText(characterCount: 2)
        try await driver.pressBack()
        try await driver.launchApp(appID: "com.example.notes")
        try await driver.pressHome()
        try await driver.openURL("https://example.com")

        let companionCalls = await companion.actionCalls()
        let openURLCalls = await simctl.openURLCalls()
        let hierarchy = try await driver.getViewHierarchy()
        let hierarchyContext = await companion.lastHierarchyContext

        XCTAssertEqual(companionCalls.doubleTapPoints, [Point(x: 1, y: 2)])
        XCTAssertEqual(companionCalls.longPresses.count, 1)
        XCTAssertEqual(companionCalls.swipes.count, 1)
        XCTAssertEqual(companionCalls.scrolls.count, 1)
        XCTAssertEqual(companionCalls.typedTexts, ["hello"])
        XCTAssertEqual(companionCalls.clearTextRequests, [2])
        XCTAssertEqual(companionCalls.pressBackCount, 1)
        XCTAssertEqual(companionCalls.pressHomeCount, 1)
        XCTAssertEqual(openURLCalls, ["https://example.com"])
        XCTAssertEqual(hierarchy.id, "root")
        XCTAssertNil(hierarchyContext?.appID)
    }

    func testTakeScreenshotFallsBackToSimctlWhenCompanionFails() async throws {
        let simctl = MockSimctlRunner()
        let companion = MockCompanionClient()
        await companion.setScreenshotError(AmooError.notImplemented("takeScreenshot"))
        let driver = IOSDriver(companion: companion, simctl: simctl)

        let screenshot = try await driver.takeScreenshot(format: .jpeg)

        XCTAssertEqual(screenshot, ScreenshotData(bytes: [0xFF], format: .jpeg))
    }

    func testRecordingErrorsForSecondSessionAndUnknownSession() async throws {
        let simctl = MockSimctlRunner()
        let driver = IOSDriver(companion: MockCompanionClient(), simctl: simctl)

        _ = try await driver.startRecording()

        do {
            _ = try await driver.startRecording()
            XCTFail("Expected commandFailed error")
        } catch let error as AmooError {
            XCTAssertEqual(
                error,
                .commandFailed(
                    command: "startRecording",
                    output: "Only one active iOS recording is supported per driver."
                )
            )
        }

        do {
            _ = try await driver.stopRecording(sessionID: "missing")
            XCTFail("Expected commandFailed error")
        } catch let error as AmooError {
            XCTAssertEqual(
                error,
                .commandFailed(command: "stopRecording", output: "No active recording with session ID: missing")
            )
        }
    }

    func testElementQueriesAndWaitsUseCompanionContext() async throws {
        let simctl = MockSimctlRunner()
        let companion = MockCompanionClient()
        await companion.setFindElementsResponses([
            [ElementInfo(id: "login", label: "Login")],
            [ElementInfo(id: "spinner", label: "Loading")],
            []
        ])
        let driver = IOSDriver(companion: companion, simctl: simctl)

        let exists = try await driver.elementExists(.init(id: "login"))
        try await driver.waitForElement(.init(id: "login"), timeout: .defaultSwipe)
        // Budget generously: the mock clears the element on the second poll (~100ms in), so this
        // exercises the disappear path, not the timeout ceiling (that is
        // `testWaitForElementToDisappearTimesOutWhenElementPersists`). A tight 250ms budget raced
        // the 100ms poll interval and flaked on loaded CI runners.
        try await driver.waitForElementToDisappear(.init(id: "spinner"), timeout: Duration(milliseconds: 5000))

        let waitCalls = await companion.waitForElementCalls()
        XCTAssertTrue(exists)
        XCTAssertEqual(waitCalls.count, 1)
        XCTAssertEqual(waitCalls.first?.selector.id, "login")
        XCTAssertNil(waitCalls.first?.appID)
    }

    func testWaitForElementToDisappearTimesOutWhenElementPersists() async throws {
        let companion = MockCompanionClient()
        await companion.setFindElementsResponses([[ElementInfo(id: "spinner", label: "Loading")]])
        let driver = IOSDriver(companion: companion, simctl: MockSimctlRunner())

        do {
            try await driver.waitForElementToDisappear(.init(id: "spinner"), timeout: Duration(milliseconds: 1))
            XCTFail("Expected timeout error")
        } catch let error as AmooError {
            XCTAssertEqual(error, .timeout(operation: "waitForElementToDisappear", duration: Duration(milliseconds: 1)))
        }
    }

    func testKeyboardAndAIContextMethodsDelegateToCompanion() async throws {
        let companion = MockCompanionClient()
        await companion.setKeyboardVisible(true)
        await companion.setInteractableElements([ElementInfo(id: "cta", label: "Continue")])
        await companion.setFindByDescriptionResults([ElementInfo(id: "settings", label: "Settings")])
        await companion.setAppStateResult("running")
        let driver = IOSDriver(companion: companion, simctl: MockSimctlRunner())

        let keyboardVisible = try await driver.isKeyboardVisible()
        let interactable = try await driver.getInteractableElements()
        let described = try await driver.findByDescription("settings")
        let appState = try await driver.appState(appID: "com.example")

        XCTAssertTrue(keyboardVisible)
        XCTAssertEqual(interactable, [ElementInfo(id: "cta", label: "Continue")])
        XCTAssertEqual(described, [ElementInfo(id: "settings", label: "Settings")])
        // Confirms appState genuinely delegates to the companion's `.state` check rather than
        // returning a hardcoded value — it used to be a permanent `.unknown` stub.
        XCTAssertEqual(appState, .running)
    }

    func testSwipeDirectionDelegatesToCompanion() async throws {
        let companion = MockCompanionClient()
        let driver = IOSDriver(companion: companion)
        try await driver.swipe(direction: .left, distance: 300, duration: Duration(milliseconds: 400))
        let swipes = await companion.swipeDirections
        XCTAssertEqual(swipes.count, 1)
        XCTAssertEqual(swipes[0].direction, .left)
        XCTAssertEqual(swipes[0].distance, 300)
        XCTAssertNil(swipes[0].element)
    }

    func testSwipeDirectionWithElementDelegatesToCompanion() async throws {
        let companion = MockCompanionClient()
        let driver = IOSDriver(companion: companion)
        try await driver.swipe(
            direction: .right,
            distance: 200,
            duration: Duration(milliseconds: 300),
            element: ElementSelector(id: "scroll-view")
        )
        let swipes = await companion.swipeDirections
        XCTAssertEqual(swipes.count, 1)
        XCTAssertEqual(swipes[0].direction, .right)
        XCTAssertEqual(swipes[0].distance, 200)
        XCTAssertEqual(swipes[0].duration, Duration(milliseconds: 300))
        XCTAssertEqual(swipes[0].element?.id, "scroll-view")
    }
}
