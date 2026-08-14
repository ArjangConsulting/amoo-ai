import AmooCore
import CompanionProtocol
import Foundation
import IOSDriver
import ProcessRunner
import XCTest

actor MockSimctlRunner: SimctlRunning {
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

    func launch(
        device: String,
        appID: String,
        arguments _: [String],
        environment: [String: String]
    ) async throws {
        let envSuffix = environment.isEmpty
            ? ""
            : ":env=" + environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        _appCalls.append("launch:\(device):\(appID)\(envSuffix)")
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

struct WaitForElementCall {
    let selector: ElementSelector
    let timeout: Duration
    let appID: String?
    let candidateBundleIDs: [String]
}

struct ActionCallsSummary {
    let doubleTapPoints: [Point]
    let longPresses: [(point: Point, duration: Duration)]
    let swipes: [SwipeCall]
    let scrolls: [(direction: Direction, distance: Double)]
    let typedTexts: [String]
    let clearTextRequests: [Int?]
    let pressBackCount: Int
    let pressHomeCount: Int
}

actor MockCompanionClient: CompanionClient {
    // swiftlint:disable large_tuple
    private(set) var lastTapElementContext: (selector: ElementSelector, appID: String?, candidateBundleIDs: [String])?
    private(set) var lastSetTextContext: (
        selector: ElementSelector,
        text: String,
        appID: String?,
        candidateBundleIDs: [String]
    )?
    private(set) var lastFindElementsContext: (selector: ElementSelector, appID: String?, candidateBundleIDs: [String])?
    // swiftlint:enable large_tuple
    private(set) var lastHierarchyContext: (appID: String?, candidateBundleIDs: [String])?
    private var _doubleTapPoints: [Point] = []
    private var _longPresses: [(point: Point, duration: Duration)] = []
    private var _swipes: [SwipeCall] = []
    private var _scrolls: [(direction: Direction, distance: Double)] = []
    private var _typedTexts: [String] = []
    private var _clearTextRequests: [Int?] = []
    private var _pressBackCount = 0
    private var _pressHomeCount = 0
    private var _findElementsResponses: [[ElementInfo]] = []
    private var _waitForElementCalls: [WaitForElementCall] = []
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

    func setText(
        _ selector: ElementSelector,
        text: String,
        appID: String?,
        candidateBundleIDs: [String]
    ) async throws {
        lastSetTextContext = (selector, text, appID, candidateBundleIDs)
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
        _waitForElementCalls.append(
            WaitForElementCall(
                selector: selector,
                timeout: timeout,
                appID: appID,
                candidateBundleIDs: candidateBundleIDs
            )
        )
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

    func actionCalls() -> ActionCallsSummary {
        ActionCallsSummary(
            doubleTapPoints: _doubleTapPoints,
            longPresses: _longPresses,
            swipes: _swipes,
            scrolls: _scrolls,
            typedTexts: _typedTexts,
            clearTextRequests: _clearTextRequests,
            pressBackCount: _pressBackCount,
            pressHomeCount: _pressHomeCount
        )
    }

    func setFindElementsResponses(_ responses: [[ElementInfo]]) {
        _findElementsResponses = responses
    }

    func waitForElementCalls() -> [WaitForElementCall] {
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
