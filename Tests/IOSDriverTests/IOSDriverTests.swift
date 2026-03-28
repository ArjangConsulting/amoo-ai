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
            "uninstall:booted:com.example.app",
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
            "appearance:booted:dark",
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
}

private actor MockSimctlRunner: SimctlRunning {
    private var bootStatusCalls: [String] = []
    private var shutdownCalls: [String] = []
    private var _appCalls: [String] = []
    private var _configCalls: [String] = []
    private var _listInstalledAppIDsCallCount = 0
    private var _recordingStarts: [(device: String, outputPath: String)] = []
    private var _recordingStops: [Int32] = []

    func run(_ arguments: [String]) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: arguments.joined(separator: " "), stderr: "")
    }

    func bootStatus(device: String) async throws {
        bootStatusCalls.append(device)
    }

    func shutdown(device: String) async throws {
        shutdownCalls.append(device)
    }

    func listDevices() async throws -> String { "{}" }

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

    func listApps(device _: String) async throws -> String { "[]" }

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

    func openURL(device _: String, url _: String) async throws {}

    func listInstalledAppIDs(device _: String) async throws -> [String] {
        _listInstalledAppIDsCallCount += 1
        return []
    }

    func calls() -> (bootStatusCalls: [String], shutdownCalls: [String]) {
        (bootStatusCalls, shutdownCalls)
    }

    func appCalls() -> [String] { _appCalls }
    func configCalls() -> [String] { _configCalls }
    func listInstalledAppIDsCallCount() -> Int { _listInstalledAppIDsCallCount }
    func recordingCalls() -> (started: [(device: String, outputPath: String)], stopped: [Int32]) {
        (_recordingStarts, _recordingStops)
    }
}

private actor MockCompanionClient: CompanionClient {
    private(set) var lastTapElementContext: (selector: ElementSelector, appID: String?, candidateBundleIDs: [String])?
    private(set) var lastFindElementsContext: (selector: ElementSelector, appID: String?, candidateBundleIDs: [String])?
    private(set) var lastHierarchyContext: (appID: String?, candidateBundleIDs: [String])?

    func startSession() async throws {}
    func endSession() async throws {}
    func getCapabilities() async throws -> [CapabilityDescriptor] { [] }

    func tap(at _: Point) async throws {}
    func doubleTap(at _: Point) async throws {}
    func longPress(at _: Point, duration _: Duration) async throws {}
    func tapElement(_ selector: ElementSelector, appID: String?, candidateBundleIDs: [String]) async throws {
        lastTapElementContext = (selector, appID, candidateBundleIDs)
    }

    func swipe(from _: Point, to _: Point, duration _: Duration) async throws {}
    func scroll(direction _: Direction, distance _: Double) async throws {}

    func typeText(_: String) async throws {}
    func clearText(characterCount _: Int?) async throws {}
    func pressBack() async throws {}

    func findElements(_ selector: ElementSelector, appID: String?, candidateBundleIDs: [String]) async throws
        -> [ElementInfo] {
        lastFindElementsContext = (selector, appID, candidateBundleIDs)
        return []
    }
    func getViewHierarchy(appID: String?, candidateBundleIDs: [String]) async throws -> ViewNode {
        lastHierarchyContext = (appID, candidateBundleIDs)
        return ViewNode(id: "root")
    }
    func waitForElement(_: ElementSelector, timeout _: Duration, appID _: String?, candidateBundleIDs _: [String])
        async throws {}
    func isKeyboardVisible() async throws -> Bool { false }

    func takeScreenshot() async throws -> ScreenshotData { ScreenshotData(bytes: [0xFF], format: .png) }

    func getScreenContext() async throws -> ScreenContext { ScreenContext(summary: "Empty screen context") }
    func getInteractableElements() async throws -> [ElementInfo] { [] }
    func findByDescription(_: String) async throws -> [ElementInfo] { [] }

    func shutdown() async {}
}
