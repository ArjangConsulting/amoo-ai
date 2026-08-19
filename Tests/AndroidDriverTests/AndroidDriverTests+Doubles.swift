import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import ProcessRunner
import XCTest

actor MockADBRunner: ADBRunning {
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
    private var _failingRawCommandSuffix: [String]?
    private var _listDevicesCallCount = 0
    private var _deviceOutputs = ["List of devices attached\nemulator-5554\tdevice product:sdk_gphone\n"]

    func run(_ arguments: [String]) async throws -> ProcessResult {
        _rawCommands.append(arguments)
        if let failing = _failingRawCommandSuffix, Array(arguments.suffix(failing.count)) == failing {
            throw AmooError.commandFailed(command: arguments.joined(separator: " "), output: "exit 1")
        }
        if arguments.count >= 3, arguments[arguments.count - 3] == "pull" {
            _pulledFiles.append((arguments[arguments.count - 2], arguments[arguments.count - 1]))
        }
        let isBootProperty = Array(arguments.suffix(3)) == ["shell", "getprop", "sys.boot_completed"]
        let stdout = isBootProperty ? "1\n" : arguments.joined(separator: " ")
        return ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    func startServer() async throws {
        startServerCalls += 1
    }

    func killEmulator(serial: String?) async throws {
        killCalls.append(serial)
    }

    func listDevices() async throws -> String {
        _listDevicesCallCount += 1
        if _deviceOutputs.count > 1 {
            return _deviceOutputs.removeFirst()
        }
        return _deviceOutputs[0]
    }

    func install(serial _: String?, apkPath: String) async throws {
        _appCalls.append("install:com.example.app:\(apkPath)")
    }

    func launch(serial _: String?, appID: String, arguments _: [String]) async throws {
        _appCalls.append("launch:\(appID)")
    }

    func launchResetting(serial _: String?, appID: String) async throws {
        _appCalls.append("launchResetting:\(appID)")
    }

    func terminate(serial _: String?, appID: String) async throws {
        _appCalls.append("terminate:\(appID)")
    }

    func uninstall(serial _: String?, appID: String) async throws {
        _appCalls.append("uninstall:\(appID)")
    }

    func clearAppData(serial _: String?, appID: String) async throws {
        _appCalls.append("clearAppData:\(appID)")
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

    func setFailingRawCommandSuffix(_ suffix: [String]?) {
        _failingRawCommandSuffix = suffix
    }

    func setDeviceOutputs(_ outputs: [String]) {
        _deviceOutputs = outputs
    }

    func listDevicesCallCount() -> Int {
        _listDevicesCallCount
    }
}

actor MockEmulatorRunner: EmulatorRunning {
    private(set) var launches: [String] = []

    func launch(avdName: String, port: Int) async throws {
        launches.append("\(avdName):\(port)")
    }
}

struct SwipeCall {
    let from: Point
    let to: Point
    let duration: Duration
}

struct SwipeDirectionCall {
    let direction: Direction
    let distance: Double
    let duration: Duration
    let element: ElementSelector?
}

struct ActionCallsSummary {
    let doubleTapPoints: [Point]
    let longPresses: [(point: Point, duration: Duration)]
    let tappedElements: [ElementSelector]
    let swipes: [SwipeCall]
    let scrolls: [(direction: Direction, distance: Double)]
    let typedTexts: [String]
    let clearTextRequests: [Int?]
    let pressBackCount: Int
}

actor MockCompanionClient: CompanionClient {
    private var _doubleTapPoints: [Point] = []
    private var _longPresses: [(point: Point, duration: Duration)] = []
    private var _tappedElements: [ElementSelector] = []
    private var _swipes: [SwipeCall] = []
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
        _swipes.append(SwipeCall(from: from, to: to, duration: duration))
    }

    private var _swipeDirections: [SwipeDirectionCall] = []

    var swipeDirections: [SwipeDirectionCall] {
        _swipeDirections
    }

    func swipeInDirection(
        _ direction: Direction,
        distance: Double,
        duration: Duration,
        element: ElementSelector?
    ) async throws {
        _swipeDirections.append(
            SwipeDirectionCall(direction: direction, distance: distance, duration: duration, element: element)
        )
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

    func actionCalls() -> ActionCallsSummary {
        ActionCallsSummary(
            doubleTapPoints: _doubleTapPoints,
            longPresses: _longPresses,
            tappedElements: _tappedElements,
            swipes: _swipes,
            scrolls: _scrolls,
            typedTexts: _typedTexts,
            clearTextRequests: _clearTextRequests,
            pressBackCount: _pressBackCount
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
