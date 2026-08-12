import AmooCore
import CompanionProtocol
import Foundation
import IOSDriver
import ProcessRunner
import XCTest

final class PhysicalDeviceHostBackendTests: XCTestCase {
    // MARK: - Capability Gap

    func testSetPermissionIsRejectedOnPhysicalDevice() async throws {
        let devicectl = MockDeviceCtlRunner()
        let driver = IOSDriver.physicalDevice(
            companion: MockDeviceCompanionClient(),
            devicectl: devicectl,
            deviceID: "00008030-001234567890ABCD"
        )

        do {
            try await driver.setPermission(
                PermissionChange(appID: "com.example.app", permission: "photos", granted: true)
            )
            XCTFail("Expected setPermission to fail on a physical device")
        } catch let error as AmooError {
            // Must fail loudly rather than silently no-op, so a test never runs against
            // a permission state it thinks it set.
            guard case let .unsupportedCapability(key, reason) = error else {
                return XCTFail("Expected unsupportedCapability, got \(error)")
            }
            XCTAssertEqual(key, "config.setPermission")
            XCTAssertTrue(reason.contains("photos"))
            XCTAssertTrue(reason.contains("com.example.app"))
        }
    }

    // MARK: - Supported Configuration

    func testLocationAndAppearanceAreSupportedOnPhysicalDevice() async throws {
        let devicectl = MockDeviceCtlRunner()
        let driver = IOSDriver.physicalDevice(
            companion: MockDeviceCompanionClient(),
            devicectl: devicectl,
            deviceID: "device-1"
        )

        try await driver.setLocation(latitude: 37.7749, longitude: -122.4194)
        try await driver.clearLocation()
        try await driver.setAppearance(.dark)

        let calls = await devicectl.calls()
        XCTAssertEqual(calls, [
            "setLocation:device-1:37.7749,-122.4194",
            "clearLocation:device-1",
            "setAppearance:device-1:dark"
        ])
    }

    // MARK: - Recording

    func testRecordingUsesMP4ContainerOnPhysicalDevice() async throws {
        let devicectl = MockDeviceCtlRunner()
        let driver = IOSDriver.physicalDevice(
            companion: MockDeviceCompanionClient(),
            devicectl: devicectl,
            deviceID: "device-1"
        )

        let session = try await driver.startRecording()
        let path = try await driver.stopRecording(sessionID: session.id)

        // devicectl rejects any destination that isn't .mp4, unlike simctl's .mov.
        XCTAssertTrue(path.hasSuffix(".mp4"), "expected .mp4 destination, got \(path)")

        let starts = await devicectl.recordingStarts()
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.device, "device-1")
    }

    func testSimulatorRecordingStillUsesMOVContainer() async throws {
        let driver = IOSDriver(
            companion: MockDeviceCompanionClient(),
            simctl: RecordingOnlySimctlRunner(),
            deviceID: "booted"
        )

        let session = try await driver.startRecording()
        let path = try await driver.stopRecording(sessionID: session.id)

        XCTAssertTrue(path.hasSuffix(".mov"), "expected .mov destination, got \(path)")
    }

    // MARK: - Parsing

    func testParseDeviceInfoReadsDevicectlJSON() {
        let json = """
        {
          "result": {
            "devices": [
              {
                "identifier": "ABC-123",
                "deviceProperties": { "name": "Mani's iPhone", "osVersionNumber": "18.2" },
                "hardwareProperties": { "udid": "00008030-001234567890ABCD" },
                "connectionProperties": { "tunnelState": "connected" }
              }
            ]
          }
        }
        """

        let info = PhysicalDeviceHostBackend.parseDeviceInfo(
            json: json, deviceID: "00008030-001234567890ABCD"
        )

        XCTAssertEqual(info.id, "00008030-001234567890ABCD")
        XCTAssertEqual(info.name, "Mani's iPhone")
        XCTAssertEqual(info.osVersion, "18.2")
        XCTAssertEqual(info.platform, .ios)
        XCTAssertEqual(info.state, .booted)
    }

    func testParseDeviceInfoMatchesByNameAndReportsDisconnected() {
        let json = """
        {
          "result": {
            "devices": [
              {
                "identifier": "ABC-123",
                "deviceProperties": { "name": "Test iPad", "osVersionNumber": "17.0" },
                "hardwareProperties": { "udid": "udid-1" },
                "connectionProperties": { "tunnelState": "unavailable" }
              }
            ]
          }
        }
        """

        let info = PhysicalDeviceHostBackend.parseDeviceInfo(json: json, deviceID: "Test iPad")

        XCTAssertEqual(info.id, "udid-1")
        // A device we can't tunnel to is not drivable, so it must not report as booted.
        XCTAssertEqual(info.state, .shutdown)
    }

    func testParseDeviceInfoReturnsUnknownForMissingDevice() {
        let info = PhysicalDeviceHostBackend.parseDeviceInfo(
            json: #"{"result": {"devices": []}}"#, deviceID: "nope"
        )

        XCTAssertEqual(info.state, .unknown)
        XCTAssertEqual(info.osVersion, "unknown")
    }

    func testParseDeviceInfoSurvivesMalformedJSON() {
        let info = PhysicalDeviceHostBackend.parseDeviceInfo(json: "not json", deviceID: "d1")
        XCTAssertEqual(info.state, .unknown)
    }

    func testParseAppListReadsDevicectlJSON() {
        let json = """
        {
          "result": {
            "apps": [
              { "bundleIdentifier": "com.example.one", "name": "One", "version": "1.2" },
              { "bundleIdentifier": "com.example.two" },
              { "name": "No bundle id" }
            ]
          }
        }
        """

        let apps = PhysicalDeviceHostBackend.parseAppList(json: json)

        // The entry without a bundle identifier is unusable and must be dropped.
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps.first?.appID, "com.example.one")
        XCTAssertEqual(apps.first?.name, "One")
        XCTAssertEqual(apps.first?.version, "1.2")
        XCTAssertEqual(apps.last?.appID, "com.example.two")
    }

    func testScreenshotReportsPNGRegardlessOfRequestedFormat() async throws {
        let backend = PhysicalDeviceHostBackend(devicectl: MockDeviceCtlRunner())

        // devicectl only writes PNG; the returned format must reflect reality, not the request.
        let shot = try await backend.screenshot(device: "device-1", format: .jpeg)

        XCTAssertEqual(shot.format, .png)
    }
}

// MARK: - Test Doubles

private actor MockDeviceCtlRunner: DeviceCtlRunning {
    private var _calls: [String] = []
    private var _recordingStarts: [(device: String, outputPath: String)] = []
    private var _devicesJSON = "{}"
    private var _appsJSON = "{}"

    func calls() -> [String] {
        _calls
    }

    func recordingStarts() -> [(device: String, outputPath: String)] {
        _recordingStarts
    }

    func run(_ arguments: [String]) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: arguments.joined(separator: " "), stderr: "")
    }

    func listDevices() async throws -> String {
        _devicesJSON
    }

    func install(device: String, appPath: String) async throws {
        _calls.append("install:\(device):\(appPath)")
    }

    func launch(
        device: String,
        appID: String,
        arguments _: [String],
        environment _: [String: String]
    ) async throws {
        _calls.append("launch:\(device):\(appID)")
    }

    func terminate(device: String, appID: String) async throws {
        _calls.append("terminate:\(device):\(appID)")
    }

    func uninstall(device: String, appID: String) async throws {
        _calls.append("uninstall:\(device):\(appID)")
    }

    func listApps(device _: String) async throws -> String {
        _appsJSON
    }

    func screenshot(device _: String) async throws -> Data {
        Data([0xFF])
    }

    func startRecording(device: String, outputPath: String) async throws -> Int32 {
        _recordingStarts.append((device, outputPath))
        return 9191
    }

    func stopRecording(pid: Int32) async throws {
        _calls.append("stopRecording:\(pid)")
    }

    func setLocation(device: String, latitude: Double, longitude: Double) async throws {
        _calls.append("setLocation:\(device):\(latitude),\(longitude)")
    }

    func clearLocation(device: String) async throws {
        _calls.append("clearLocation:\(device)")
    }

    func setAppearance(device: String, appearance: Appearance) async throws {
        _calls.append("setAppearance:\(device):\(appearance.rawValue)")
    }

    func openURL(device: String, url: String) async throws {
        _calls.append("openURL:\(device):\(url)")
    }
}

/// Minimal `SimctlRunning` covering only what the recording-container test exercises.
private struct RecordingOnlySimctlRunner: SimctlRunning {
    func run(_: [String]) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func bootStatus(device _: String) async throws {}
    func shutdown(device _: String) async throws {}
    func listDevices() async throws -> String {
        "{}"
    }

    func install(device _: String, appPath _: String) async throws {}
    func launch(
        device _: String,
        appID _: String,
        arguments _: [String],
        environment _: [String: String]
    ) async throws {}
    func terminate(device _: String, appID _: String) async throws {}
    func uninstall(device _: String, appID _: String) async throws {}
    func listApps(device _: String) async throws -> String {
        "[]"
    }

    func screenshot(device _: String, format _: ImageFormat) async throws -> Data {
        Data()
    }

    func startRecording(device _: String, outputPath _: String) async throws -> Int32 {
        1
    }

    func stopRecording(pid _: Int32) async throws {}
    func setPermission(device _: String, action _: String, permission _: String, appID _: String) async throws {}
    func setLocation(device _: String, latitude _: Double, longitude _: Double) async throws {}
    func clearLocation(device _: String) async throws {}
    func setAppearance(device _: String, appearance _: Appearance) async throws {}
    func openURL(device _: String, url _: String) async throws {}
    func listInstalledAppIDs(device _: String) async throws -> [String] {
        []
    }
}

private struct MockDeviceCompanionClient: CompanionClient {
    func startSession() async throws {}
    func getCapabilities() async throws -> [CapabilityDescriptor] {
        []
    }

    func endSession() async throws {}
    func tap(at _: Point) async throws {}
    func swipe(from _: Point, to _: Point, duration _: Duration) async throws {}
    func typeText(_: String) async throws {}
    func pressBack() async throws {}
    func getScreenContext() async throws -> ScreenContext {
        ScreenContext(summary: "")
    }
}
