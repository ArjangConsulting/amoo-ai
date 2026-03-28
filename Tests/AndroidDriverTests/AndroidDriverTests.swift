import AndroidDriver
import CompanionProtocol
import Foundation
import MobileTestingCore
import ProcessRunner
import XCTest

final class AndroidDriverTests: XCTestCase {
    func testTapDelegatesToCompanion() async throws {
        let driver = AndroidDriver(companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22088)))
        try await driver.tap(at: Point(x: 8, y: 16))
        let elements = try await driver.findElements(.init(label: "Continue"))
        XCTAssertEqual(elements.first?.label, "Continue")
    }

    func testBootAndShutdownExecute() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(
            companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22088)),
            adb: adb
        )
        try await driver.boot()
        try await driver.shutdown()

        let calls = await adb.calls()
        XCTAssertEqual(calls.startServerCalls, 1)
        XCTAssertEqual(calls.killCalls, [nil])
    }

    func testContextAndCaptureAndPermission() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(
            companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22088)),
            adb: adb
        )

        let hierarchy = try await driver.getViewHierarchy()
        let context = try await driver.getScreenContext()
        let screenshot = try await driver.takeScreenshot(format: .png)

        XCTAssertEqual(hierarchy.id, "root")
        XCTAssertEqual(context.summary, "Empty screen context")
        XCTAssertEqual(screenshot.bytes, [0xAB])
    }

    func testAppLifecycleDelegatesToADB() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(
            companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22088)),
            adb: adb
        )

        try await driver.installApp(path: "/tmp/app.apk")
        try await driver.launchApp(appID: "com.example.app")
        try await driver.terminateApp(appID: "com.example.app")
        try await driver.uninstallApp(appID: "com.example.app")

        let appCalls = await adb.appCalls()
        XCTAssertEqual(appCalls, [
            "install:com.example.app:/tmp/app.apk",
            "launch:com.example.app",
            "terminate:com.example.app",
            "uninstall:com.example.app"
        ])
    }

    func testPermissionDelegatesToADB() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(
            companion: GRPCCompanionClient(connection: .init(host: "127.0.0.1", port: 22088)),
            adb: adb
        )

        try await driver.setPermission(.init(
            appID: "com.example",
            permission: "android.permission.CAMERA",
            granted: true
        ))
        try await driver.setPermission(.init(
            appID: "com.example",
            permission: "android.permission.CAMERA",
            granted: false
        ))

        let permCalls = await adb.permissionCalls()
        XCTAssertEqual(permCalls, [
            "grant:com.example:android.permission.CAMERA",
            "revoke:com.example:android.permission.CAMERA"
        ])
    }

    func testRecordingPullsArtifactAndReturnsLocalPath() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)

        let session = try await driver.startRecording()
        let outputPath = try await driver.stopRecording(sessionID: session.id)

        let recordingCalls = await adb.recordingCalls()
        XCTAssertEqual(recordingCalls.started.count, 1)
        XCTAssertEqual(recordingCalls.stopped, 1)
        XCTAssertTrue(recordingCalls.pulls.first?.remotePath.hasSuffix(".mp4") == true)
        XCTAssertTrue(outputPath.hasSuffix(".mp4"))
    }

    func testDeviceInfoUsesSerialWhenProvided() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb, serial: "emulator-5554")

        let info = try await driver.deviceInfo()
        let listDevicesCallCount = await adb.listDevicesCallCount()

        XCTAssertEqual(info.id, "emulator-5554")
        XCTAssertEqual(info.name, "emulator-5554")
        XCTAssertEqual(info.platform, .android)
        XCTAssertEqual(info.osVersion, "unknown")
        XCTAssertEqual(info.state, .booted)
        XCTAssertEqual(listDevicesCallCount, 1)
    }

    func testListAppsFiltersBlankPackageEntries() async throws {
        let adb = MockADBRunner()
        await adb.setPackageList("package:com.example.one\n\npackage: com.example.two \npackage:\n")
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)

        let apps = try await driver.listApps()

        XCTAssertEqual(apps, [AppInfo(appID: "com.example.one"), AppInfo(appID: "com.example.two")])
    }

    func testDelegatesRemainingCompanionAndADBOperations() async throws {
        let adb = MockADBRunner()
        let companion = MockCompanionClient()
        let driver = AndroidDriver(companion: companion, adb: adb, serial: "emulator-5554")

        try await driver.doubleTap(at: Point(x: 1, y: 2))
        try await driver.longPress(at: Point(x: 3, y: 4), duration: .defaultLongPress)
        try await driver.tapElement(.init(id: "login"))
        try await driver.swipe(from: Point(x: 0, y: 0), to: Point(x: 50, y: 100), duration: .defaultSwipe)
        try await driver.scroll(direction: .down, distance: 120)
        try await driver.typeText("hello")
        try await driver.clearText(characterCount: 3)
        try await driver.pressBack()
        try await driver.pressHome()
        try await driver.openURL("myapp://details")

        let actionCalls = await companion.actionCalls()
        let rawCommands = await adb.rawCommands()
        let openURLCalls = await adb.openURLCalls()

        XCTAssertEqual(actionCalls.doubleTapPoints, [Point(x: 1, y: 2)])
        XCTAssertEqual(actionCalls.longPresses.count, 1)
        XCTAssertEqual(actionCalls.tappedElements, [.init(id: "login")])
        XCTAssertEqual(actionCalls.swipes.count, 1)
        XCTAssertEqual(actionCalls.scrolls.count, 1)
        XCTAssertEqual(actionCalls.typedTexts, ["hello"])
        XCTAssertEqual(actionCalls.clearTextRequests, [3])
        XCTAssertEqual(actionCalls.pressBackCount, 1)
        XCTAssertEqual(openURLCalls, ["myapp://details"])
        XCTAssertEqual(rawCommands, [["-s", "emulator-5554", "shell", "input", "keyevent", "KEYCODE_HOME"]])
    }

    func testRecordingErrorsForSecondSessionAndUnknownSession() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)

        _ = try await driver.startRecording()

        do {
            _ = try await driver.startRecording()
            XCTFail("Expected commandFailed error")
        } catch let error as MobileTestingError {
            XCTAssertEqual(
                error,
                .commandFailed(command: "startRecording", output: "Only one active Android recording is supported per driver.")
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

    func testElementQueriesAndWaitsUseCompanion() async throws {
        let adb = MockADBRunner()
        let companion = MockCompanionClient()
        await companion.setFindElementsResponses([
            [ElementInfo(id: "login", label: "Login")],
            [ElementInfo(id: "spinner", label: "Loading")],
            []
        ])
        let driver = AndroidDriver(companion: companion, adb: adb)

        let exists = try await driver.elementExists(.init(id: "login"))
        try await driver.waitForElement(.init(id: "login"), timeout: .defaultSwipe)
        try await driver.waitForElementToDisappear(.init(id: "spinner"), timeout: Duration(milliseconds: 250))

        let waitCalls = await companion.waitForElementCalls()
        XCTAssertTrue(exists)
        XCTAssertEqual(waitCalls.count, 1)
        XCTAssertEqual(waitCalls.first?.selector.id, "login")
    }

    func testWaitForElementToDisappearTimesOutWhenElementPersists() async throws {
        let companion = MockCompanionClient()
        await companion.setFindElementsResponses([[ElementInfo(id: "spinner", label: "Loading")]])
        let driver = AndroidDriver(companion: companion, adb: MockADBRunner())

        do {
            try await driver.waitForElementToDisappear(.init(id: "spinner"), timeout: Duration(milliseconds: 1))
            XCTFail("Expected timeout error")
        } catch let error as MobileTestingError {
            XCTAssertEqual(error, .timeout(operation: "waitForElementToDisappear", duration: Duration(milliseconds: 1)))
        }
    }

    func testLocationAppearanceKeyboardAndAIContextPaths() async throws {
        let adb = MockADBRunner()
        let companion = MockCompanionClient()
        await companion.setKeyboardVisible(true)
        await companion.setInteractableElements([ElementInfo(id: "cta", label: "Continue")])
        await companion.setFindByDescriptionResults([ElementInfo(id: "settings", label: "Settings")])
        let driver = AndroidDriver(companion: companion, adb: adb, serial: "emulator-5554")

        try await driver.setLocation(latitude: 37.5, longitude: -122.2)
        try await driver.clearLocation()
        try await driver.setAppearance(.dark)
        try await driver.setAppearance(.light)

        let keyboardVisible = try await driver.isKeyboardVisible()
        let interactable = try await driver.getInteractableElements()
        let described = try await driver.findByDescription("settings")
        let appState = try await driver.appState(appID: "com.example")
        let commands = await adb.rawCommands()

        XCTAssertTrue(keyboardVisible)
        XCTAssertEqual(interactable, [ElementInfo(id: "cta", label: "Continue")])
        XCTAssertEqual(described, [ElementInfo(id: "settings", label: "Settings")])
        XCTAssertEqual(appState, .unknown)
        XCTAssertEqual(commands, [
            ["-s", "emulator-5554", "emu", "geo", "fix", "-122.2", "37.5"],
            ["-s", "emulator-5554", "emu", "geo", "fix", "0.0", "0.0"],
            ["-s", "emulator-5554", "shell", "cmd", "uimode", "night", "yes"],
            ["-s", "emulator-5554", "shell", "cmd", "uimode", "night", "no"]
        ])
    }
}

private actor MockADBRunner: ADBRunning {
    private var startServerCalls = 0
    private var killCalls: [String?] = []
    private var _appCalls: [String] = []
    private var _permissionCalls: [String] = []
    private var _startedRecordings: [String] = []
    private var _stoppedRecordings = 0
    private var _pulledFiles: [(remotePath: String, localPath: String)] = []
    private var _rawCommands: [[String]] = []
    private var _openURLCalls: [String] = []
    private var _packageList = "package:com.example.app\n"
    private var _listDevicesCallCount = 0

    func run(_ arguments: [String]) async throws -> ProcessResult {
        _rawCommands.append(arguments)
        if arguments.count >= 3, arguments[arguments.count - 3] == "pull" {
            _pulledFiles.append((arguments[arguments.count - 2], arguments[arguments.count - 1]))
        }
        return ProcessResult(exitCode: 0, stdout: arguments.joined(separator: " "), stderr: "")
    }

    func startServer() async throws {
        startServerCalls += 1
    }

    func killEmulator(serial: String?) async throws {
        killCalls.append(serial)
    }

    func listDevices() async throws -> String {
        _listDevicesCallCount += 1
        return "List of devices attached\n"
    }

    func install(serial _: String?, apkPath: String) async throws {
        _appCalls.append("install:com.example.app:\(apkPath)")
    }

    func launch(serial _: String?, appID: String, arguments _: [String]) async throws {
        _appCalls.append("launch:\(appID)")
    }

    func terminate(serial _: String?, appID: String) async throws {
        _appCalls.append("terminate:\(appID)")
    }

    func uninstall(serial _: String?, appID: String) async throws {
        _appCalls.append("uninstall:\(appID)")
    }

    func listPackages(serial _: String?) async throws -> String {
        _packageList
    }

    func screenshot(serial _: String?) async throws -> Data {
        Data([0xAB])
    }

    func startRecording(serial _: String?, outputPath: String) async throws {
        _startedRecordings.append(outputPath)
    }

    func stopRecording(serial _: String?) async throws {
        _stoppedRecordings += 1
    }

    func grantPermission(serial _: String?, appID: String, permission: String) async throws {
        _permissionCalls.append("grant:\(appID):\(permission)")
    }

    func revokePermission(serial _: String?, appID: String, permission: String) async throws {
        _permissionCalls.append("revoke:\(appID):\(permission)")
    }

    func openURL(serial _: String?, url: String) async throws {
        _openURLCalls.append(url)
    }
    func forwardPort(serial _: String?, localPort _: Int, remotePort _: Int) async throws {}
    func removeForward(serial _: String?, localPort _: Int) async throws {}

    func calls() -> (startServerCalls: Int, killCalls: [String?]) {
        (startServerCalls, killCalls)
    }

    func appCalls() -> [String] {
        _appCalls
    }

    func permissionCalls() -> [String] {
        _permissionCalls
    }

    // swiftlint:disable:next large_tuple
    func recordingCalls() -> (started: [String], stopped: Int, pulls: [(remotePath: String, localPath: String)]) {
        (_startedRecordings, _stoppedRecordings, _pulledFiles)
    }

    func rawCommands() -> [[String]] {
        _rawCommands
    }

    func openURLCalls() -> [String] {
        _openURLCalls
    }

    func setPackageList(_ output: String) {
        _packageList = output
    }

    func listDevicesCallCount() -> Int {
        _listDevicesCallCount
    }
}

private actor MockCompanionClient: CompanionClient {
    private var _doubleTapPoints: [Point] = []
    private var _longPresses: [(point: Point, duration: Duration)] = []
    private var _tappedElements: [ElementSelector] = []
    private var _swipes: [(from: Point, to: Point, duration: Duration)] = []
    private var _scrolls: [(direction: Direction, distance: Double)] = []
    private var _typedTexts: [String] = []
    private var _clearTextRequests: [Int?] = []
    private var _pressBackCount = 0
    private var _findElementsResponses: [[ElementInfo]] = []
    private var _waitForElementCalls: [(selector: ElementSelector, timeout: Duration)] = []
    private var _keyboardVisible = false
    private var _interactableElements: [ElementInfo] = []
    private var _findByDescriptionResults: [ElementInfo] = []

    func startSession() async throws {}
    func getCapabilities() async throws -> [CapabilityDescriptor] {
        []
    }

    func endSession() async throws {}

    func tap(at _: Point) async throws {}
    func doubleTap(at point: Point) async throws {
        _doubleTapPoints.append(point)
    }

    func longPress(at point: Point, duration: Duration) async throws {
        _longPresses.append((point, duration))
    }

    func tapElement(_ selector: ElementSelector, appID _: String?, candidateBundleIDs _: [String]) async throws {
        _tappedElements.append(selector)
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
    func pressHome() async throws {}

    func findElements(
        _ selector: ElementSelector,
        appID _: String?,
        candidateBundleIDs _: [String]
    ) async throws -> [ElementInfo] {
        if !_findElementsResponses.isEmpty {
            return _findElementsResponses.removeFirst()
        }
        return []
    }

    func getViewHierarchy(appID _: String?, candidateBundleIDs _: [String]) async throws -> ViewNode {
        ViewNode(id: "root")
    }

    func waitForElement(
        _ selector: ElementSelector,
        timeout: Duration,
        appID _: String?,
        candidateBundleIDs _: [String]
    ) async throws {
        _waitForElementCalls.append((selector, timeout))
    }

    func isKeyboardVisible() async throws -> Bool {
        _keyboardVisible
    }

    func takeScreenshot() async throws -> ScreenshotData {
        ScreenshotData(bytes: [0xAB])
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

    func actionCalls() -> (
        doubleTapPoints: [Point],
        longPresses: [(point: Point, duration: Duration)],
        tappedElements: [ElementSelector],
        swipes: [(from: Point, to: Point, duration: Duration)],
        scrolls: [(direction: Direction, distance: Double)],
        typedTexts: [String],
        clearTextRequests: [Int?],
        pressBackCount: Int
    ) {
        (
            _doubleTapPoints,
            _longPresses,
            _tappedElements,
            _swipes,
            _scrolls,
            _typedTexts,
            _clearTextRequests,
            _pressBackCount
        )
    }

    func setFindElementsResponses(_ responses: [[ElementInfo]]) {
        _findElementsResponses = responses
    }

    func waitForElementCalls() -> [(selector: ElementSelector, timeout: Duration)] {
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
}
