import CompanionProtocol
import Foundation
import IOSDriver
import MobileTestingCore
import ProcessRunner
import XCTest

final class IOSDriverTests: XCTestCase {
    func testTapDelegatesToCompanion() async throws {
        let driver = IOSDriver(companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22087)))
        try await driver.tap(at: Point(x: 10, y: 20))
        let elements = try await driver.findElements(.init(id: "login"))
        XCTAssertEqual(elements.first?.id, "login")
    }

    func testBootAndShutdownExecute() async throws {
        let simctl = MockSimctlRunner()
        let driver = IOSDriver(
            companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22087)),
            simctl: simctl
        )
        try await driver.boot()
        try await driver.shutdown()

        let calls = await simctl.calls()
        XCTAssertEqual(calls.bootStatusCalls, ["booted"])
        XCTAssertEqual(calls.shutdownCalls, ["booted"])
    }

    func testContextAndCaptureAndPermission() async throws {
        let simctl = MockSimctlRunner()
        let driver = IOSDriver(
            companion: MockCompanionClient(),
            simctl: simctl
        )

        let hierarchy = try await driver.getViewHierarchy()
        let context = try await driver.getScreenContext()
        let screenshot = try await driver.takeScreenshot(format: .png)

        XCTAssertEqual(hierarchy.id, "root")
        XCTAssertEqual(context.summary, "Empty screen context")
        XCTAssertEqual(screenshot.bytes, [0xFF])
    }

    func testAppLifecycleDelegatesToSimctl() async throws {
        let simctl = MockSimctlRunner()
        let driver = IOSDriver(
            companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22087)),
            simctl: simctl
        )

        try await driver.installApp(path: "/tmp/App.app")
        try await driver.launchApp(appID: "com.example.app")
        try await driver.terminateApp(appID: "com.example.app")
        try await driver.uninstallApp(appID: "com.example.app")

        let calls = await simctl.appCalls()
        XCTAssertEqual(calls, [
            "install:booted:/tmp/App.app",
            "launch:booted:com.example.app",
            "terminate:booted:com.example.app",
            "uninstall:booted:com.example.app"
        ])
    }

    func testConfigurationDelegatesToSimctl() async throws {
        let simctl = MockSimctlRunner()
        let driver = IOSDriver(
            companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22087)),
            simctl: simctl
        )

        try await driver.setPermission(.init(appID: "com.example", permission: "camera", granted: true))
        try await driver.setLocation(latitude: 37.77, longitude: -122.42)
        try await driver.clearLocation()
        try await driver.setAppearance(.dark)

        let calls = await simctl.configCalls()
        XCTAssertEqual(calls, [
            "permission:booted:grant:camera:com.example",
            "location:booted:37.77,-122.42",
            "clearLocation:booted",
            "appearance:booted:dark"
        ])
    }

    func testTapElementUsesCurrentAppIDWhenAvailable() async throws {
        let simctl = MockSimctlRunner()
        let companion = MockCompanionClient()
        let driver = IOSDriver(companion: companion, simctl: simctl)

        try await driver.launchApp(appID: "com.example.maps")
        try await driver.tapElement(.init(label: "Map"))

        let context = await companion.lastTapElementContext
        XCTAssertEqual(context?.selector.label, "Map")
        XCTAssertEqual(context?.appID, "com.example.maps")
        XCTAssertEqual(context?.candidateBundleIDs, [])
    }

    func testFindElementsDoesNotAskSimctlForInstalledAppsWithoutCurrentApp() async throws {
        let simctl = MockSimctlRunner()
        let companion = MockCompanionClient()
        let driver = IOSDriver(companion: companion, simctl: simctl)

        _ = try await driver.findElements(.init(label: "Files"))

        let context = await companion.lastFindElementsContext
        let listInstalledAppIDsCallCount = await simctl.listInstalledAppIDsCallCount()
        XCTAssertEqual(context?.selector.label, "Files")
        XCTAssertNil(context?.appID)
        XCTAssertEqual(context?.candidateBundleIDs, [])
        XCTAssertEqual(listInstalledAppIDsCallCount, 0)
    }

    func testGetViewHierarchyDoesNotAskSimctlForInstalledAppsWithoutCurrentApp() async throws {
        let simctl = MockSimctlRunner()
        let companion = MockCompanionClient()
        let driver = IOSDriver(companion: companion, simctl: simctl)

        _ = try await driver.getViewHierarchy()

        let hierarchyContext = await companion.lastHierarchyContext
        let listInstalledAppIDsCallCount = await simctl.listInstalledAppIDsCallCount()
        XCTAssertEqual(hierarchyContext?.candidateBundleIDs, [])
        XCTAssertNil(hierarchyContext?.appID)
        XCTAssertEqual(listInstalledAppIDsCallCount, 0)
    }

    func testRecordingReturnsArtifactPathAndStopsTrackedPID() async throws {
        let simctl = MockSimctlRunner()
        let driver = IOSDriver(companion: MockCompanionClient(), simctl: simctl)

        let session = try await driver.startRecording()
        let outputPath = try await driver.stopRecording(sessionID: session.id)

        let recordingCalls = await simctl.recordingCalls()
        XCTAssertEqual(recordingCalls.started.count, 1)
        XCTAssertEqual(recordingCalls.stopped, [4242])
        XCTAssertTrue(outputPath.hasSuffix(".mov"))
    }

    func testDeviceInfoParsesBootedSimulator() async throws {
        let simctl = MockSimctlRunner()
        await simctl.setDevicesJSON(
            """
            {
              "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
                  {
                    "udid": "A1B2",
                    "state": "Booted",
                    "name": "iPhone 16 Pro"
                  }
                ]
              }
            }
            """
        )
        let driver = IOSDriver(companion: MockCompanionClient(), simctl: simctl, deviceID: "booted")

        let info = try await driver.deviceInfo()

        XCTAssertEqual(info.id, "A1B2")
        XCTAssertEqual(info.name, "iPhone 16 Pro")
        XCTAssertEqual(info.platform, .ios)
        XCTAssertEqual(info.osVersion, "18.2")
        XCTAssertEqual(info.state, .booted)
    }

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
        await companion.setScreenshotError(MobileTestingError.notImplemented("takeScreenshot"))
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
        } catch let error as MobileTestingError {
            XCTAssertEqual(
                error,
                .commandFailed(command: "startRecording", output: "Only one active iOS recording is supported per driver.")
            )
        }

        do {
            _ = try await driver.stopRecording(sessionID: "missing")
            XCTFail("Expected commandFailed error")
        } catch let error as MobileTestingError {
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
        try await driver.waitForElementToDisappear(.init(id: "spinner"), timeout: Duration(milliseconds: 250))

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
        } catch let error as MobileTestingError {
            XCTAssertEqual(error, .timeout(operation: "waitForElementToDisappear", duration: Duration(milliseconds: 1)))
        }
    }

    func testKeyboardAndAIContextMethodsDelegateToCompanion() async throws {
        let companion = MockCompanionClient()
        await companion.setKeyboardVisible(true)
        await companion.setInteractableElements([ElementInfo(id: "cta", label: "Continue")])
        await companion.setFindByDescriptionResults([ElementInfo(id: "settings", label: "Settings")])
        let driver = IOSDriver(companion: companion, simctl: MockSimctlRunner())

        let keyboardVisible = try await driver.isKeyboardVisible()
        let interactable = try await driver.getInteractableElements()
        let described = try await driver.findByDescription("settings")
        let appState = try await driver.appState(appID: "com.example")

        XCTAssertTrue(keyboardVisible)
        XCTAssertEqual(interactable, [ElementInfo(id: "cta", label: "Continue")])
        XCTAssertEqual(described, [ElementInfo(id: "settings", label: "Settings")])
        XCTAssertEqual(appState, .unknown)
    }
}

private actor MockSimctlRunner: SimctlRunning {
    private var bootStatusCalls: [String] = []
    private var shutdownCalls: [String] = []
    private var _appCalls: [String] = []
    private var _configCalls: [String] = []
    private var _listInstalledAppIDsCallCount = 0
    private var _recordingStarts: [(device: String, outputPath: String)] = []
    private var _recordingStops: [Int32] = []
    private var _devicesJSON = "{}"
    private var _appListOutput = "[]"
    private var _openURLCalls: [String] = []

    func run(_ arguments: [String]) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: arguments.joined(separator: " "), stderr: "")
    }

    func bootStatus(device: String) async throws {
        bootStatusCalls.append(device)
    }

    func shutdown(device: String) async throws {
        shutdownCalls.append(device)
    }

    func listDevices() async throws -> String {
        _devicesJSON
    }

    func install(device: String, appPath: String) async throws {
        _appCalls.append("install:\(device):\(appPath)")
    }

    func launch(device: String, appID: String, arguments _: [String]) async throws {
        _appCalls.append("launch:\(device):\(appID)")
    }

    func terminate(device: String, appID: String) async throws {
        _appCalls.append("terminate:\(device):\(appID)")
    }

    func uninstall(device: String, appID: String) async throws {
        _appCalls.append("uninstall:\(device):\(appID)")
    }

    func listApps(device _: String) async throws -> String {
        _appListOutput
    }

    func screenshot(device _: String, format _: ImageFormat) async throws -> Data {
        Data([0xFF])
    }

    func startRecording(device: String, outputPath: String) async throws -> Int32 {
        _recordingStarts.append((device, outputPath))
        return 4242
    }

    func stopRecording(pid: Int32) async throws {
        _recordingStops.append(pid)
    }

    func setPermission(device: String, action: String, permission: String, appID: String) async throws {
        _configCalls.append("permission:\(device):\(action):\(permission):\(appID)")
    }

    func setLocation(device: String, latitude: Double, longitude: Double) async throws {
        _configCalls.append("location:\(device):\(latitude),\(longitude)")
    }

    func clearLocation(device: String) async throws {
        _configCalls.append("clearLocation:\(device)")
    }

    func setAppearance(device: String, appearance: Appearance) async throws {
        _configCalls.append("appearance:\(device):\(appearance.rawValue)")
    }

    func openURL(device _: String, url: String) async throws {
        _openURLCalls.append(url)
    }

    func listInstalledAppIDs(device _: String) async throws -> [String] {
        _listInstalledAppIDsCallCount += 1
        return []
    }

    func calls() -> (bootStatusCalls: [String], shutdownCalls: [String]) {
        (bootStatusCalls, shutdownCalls)
    }

    func appCalls() -> [String] {
        _appCalls
    }

    func configCalls() -> [String] {
        _configCalls
    }

    func listInstalledAppIDsCallCount() -> Int {
        _listInstalledAppIDsCallCount
    }

    func recordingCalls() -> (started: [(device: String, outputPath: String)], stopped: [Int32]) {
        (_recordingStarts, _recordingStops)
    }

    func setDevicesJSON(_ json: String) {
        _devicesJSON = json
    }

    func setAppListOutput(_ output: String) {
        _appListOutput = output
    }

    func openURLCalls() -> [String] {
        _openURLCalls
    }
}

private actor MockCompanionClient: CompanionClient {
    // swiftlint:disable large_tuple
    private(set) var lastTapElementContext: (selector: ElementSelector, appID: String?, candidateBundleIDs: [String])?
    private(set) var lastFindElementsContext: (selector: ElementSelector, appID: String?, candidateBundleIDs: [String])?
    // swiftlint:enable large_tuple
    private(set) var lastHierarchyContext: (appID: String?, candidateBundleIDs: [String])?
    private var _doubleTapPoints: [Point] = []
    private var _longPresses: [(point: Point, duration: Duration)] = []
    private var _swipes: [(from: Point, to: Point, duration: Duration)] = []
    private var _scrolls: [(direction: Direction, distance: Double)] = []
    private var _typedTexts: [String] = []
    private var _clearTextRequests: [Int?] = []
    private var _pressBackCount = 0
    private var _pressHomeCount = 0
    private var _findElementsResponses: [[ElementInfo]] = []
    private var _waitForElementCalls: [(selector: ElementSelector, timeout: Duration, appID: String?, candidateBundleIDs: [String])] = []
    private var _keyboardVisible = false
    private var _interactableElements: [ElementInfo] = []
    private var _findByDescriptionResults: [ElementInfo] = []
    private var _screenshotError: Error?

    func startSession() async throws {}
    func endSession() async throws {}
    func getCapabilities() async throws -> [CapabilityDescriptor] {
        []
    }

    func tap(at _: Point) async throws {}
    func doubleTap(at point: Point) async throws {
        _doubleTapPoints.append(point)
    }

    func longPress(at point: Point, duration: Duration) async throws {
        _longPresses.append((point, duration))
    }
    func tapElement(_ selector: ElementSelector, appID: String?, candidateBundleIDs: [String]) async throws {
        lastTapElementContext = (selector, appID, candidateBundleIDs)
    }

    func swipe(from: Point, to: Point, duration: Duration) async throws {
        _swipes.append((from, to, duration))
    }

    func scroll(direction: Direction, distance: Double) async throws {
        _scrolls.append((direction, distance))
    }

    func typeText(_ text: String) async throws {
        _typedTexts.append(text)
    }

    func clearText(characterCount: Int?) async throws {
        _clearTextRequests.append(characterCount)
    }

    func pressBack() async throws {
        _pressBackCount += 1
    }

    func pressHome() async throws {
        _pressHomeCount += 1
    }

    func findElements(_ selector: ElementSelector, appID: String?, candidateBundleIDs: [String]) async throws
        -> [ElementInfo] {
        lastFindElementsContext = (selector, appID, candidateBundleIDs)
        if !_findElementsResponses.isEmpty {
            return _findElementsResponses.removeFirst()
        }
        return []
    }

    func getViewHierarchy(appID: String?, candidateBundleIDs: [String]) async throws -> ViewNode {
        lastHierarchyContext = (appID, candidateBundleIDs)
        return ViewNode(id: "root")
    }

    func waitForElement(
        _ selector: ElementSelector,
        timeout: Duration,
        appID: String?,
        candidateBundleIDs: [String]
    ) async throws {
        _waitForElementCalls.append((selector: selector, timeout: timeout, appID: appID, candidateBundleIDs: candidateBundleIDs))
    }
    func isKeyboardVisible() async throws -> Bool {
        _keyboardVisible
    }

    func takeScreenshot() async throws -> ScreenshotData {
        if let screenshotError = _screenshotError {
            throw screenshotError
        }
        return ScreenshotData(bytes: [0xFF], format: .png)
    }

    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "Empty screen context")
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        _interactableElements
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        _findByDescriptionResults
    }

    func shutdown() async {}

    func actionCalls() -> (
        doubleTapPoints: [Point],
        longPresses: [(point: Point, duration: Duration)],
        swipes: [(from: Point, to: Point, duration: Duration)],
        scrolls: [(direction: Direction, distance: Double)],
        typedTexts: [String],
        clearTextRequests: [Int?],
        pressBackCount: Int,
        pressHomeCount: Int
    ) {
        (
            _doubleTapPoints,
            _longPresses,
            _swipes,
            _scrolls,
            _typedTexts,
            _clearTextRequests,
            _pressBackCount,
            _pressHomeCount
        )
    }

    func setFindElementsResponses(_ responses: [[ElementInfo]]) {
        _findElementsResponses = responses
    }

    func waitForElementCalls() -> [(selector: ElementSelector, timeout: Duration, appID: String?, candidateBundleIDs: [String])] {
        _waitForElementCalls
    }

    func setKeyboardVisible(_ visible: Bool) {
        _keyboardVisible = visible
    }

    func setInteractableElements(_ elements: [ElementInfo]) {
        _interactableElements = elements
    }

    func setFindByDescriptionResults(_ elements: [ElementInfo]) {
        _findByDescriptionResults = elements
    }

    func setScreenshotError(_ error: Error?) {
        _screenshotError = error
    }
}
