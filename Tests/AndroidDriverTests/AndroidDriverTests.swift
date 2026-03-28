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
}

private actor MockADBRunner: ADBRunning {
    private var startServerCalls = 0
    private var killCalls: [String?] = []
    private var _appCalls: [String] = []
    private var _permissionCalls: [String] = []
    private var _startedRecordings: [String] = []
    private var _stoppedRecordings = 0
    private var _pulledFiles: [(remotePath: String, localPath: String)] = []

    func run(_ arguments: [String]) async throws -> ProcessResult {
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
        "List of devices attached\n"
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
        "package:com.example.app\n"
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

    func openURL(serial _: String?, url _: String) async throws {}
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
}

private actor MockCompanionClient: CompanionClient {
    func startSession() async throws {}
    func getCapabilities() async throws -> [CapabilityDescriptor] {
        []
    }

    func endSession() async throws {}

    func tap(at _: Point) async throws {}
    func doubleTap(at _: Point) async throws {}
    func longPress(at _: Point, duration _: Duration) async throws {}
    func tapElement(_: ElementSelector, appID _: String?, candidateBundleIDs _: [String]) async throws {}

    func swipe(from _: Point, to _: Point, duration _: Duration) async throws {}
    func scroll(direction _: Direction, distance _: Double) async throws {}

    func typeText(_: String) async throws {}
    func clearText(characterCount _: Int?) async throws {}
    func pressBack() async throws {}
    func pressHome() async throws {}

    func findElements(
        _: ElementSelector,
        appID _: String?,
        candidateBundleIDs _: [String]
    ) async throws -> [ElementInfo] {
        []
    }

    func getViewHierarchy(appID _: String?, candidateBundleIDs _: [String]) async throws -> ViewNode {
        ViewNode(id: "root")
    }

    func waitForElement(
        _: ElementSelector,
        timeout _: Duration,
        appID _: String?,
        candidateBundleIDs _: [String]
    ) async throws {}

    func isKeyboardVisible() async throws -> Bool {
        false
    }

    func takeScreenshot() async throws -> ScreenshotData {
        ScreenshotData(bytes: [0xAB])
    }

    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "Empty screen context")
    }

    func getInteractableElements() async throws -> [ElementInfo] {
        []
    }

    func findByDescription(_: String) async throws -> [ElementInfo] {
        []
    }
}
