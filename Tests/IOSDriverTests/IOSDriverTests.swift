import AmooCore
import CompanionProtocol
import Foundation
import IOSDriver
import ProcessRunner
import XCTest

final class IOSDriverTests: XCTestCase {
    func testTapDelegatesToCompanion() async throws {
        let driver = IOSDriver(companion: GRPCCompanionClient.makeFixture(connection: .init(
            host: "127.0.0.1",
            port: 22087
        )))
        try await driver.tap(at: Point(x: 10, y: 20))
        let elements = try await driver.findElements(.init(id: "login"))
        XCTAssertEqual(elements.first?.id, "login")
    }

    func testBootAndShutdownExecute() async throws {
        let simctl = MockSimctlRunner()
        let driver = IOSDriver(
            companion: GRPCCompanionClient.makeFixture(connection: .init(host: "127.0.0.1", port: 22087)),
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
            companion: GRPCCompanionClient.makeFixture(connection: .init(host: "127.0.0.1", port: 22087)),
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

    func testLaunchAppPassesEnvironmentThroughSimctl() async throws {
        let simctl = MockSimctlRunner()
        let driver = IOSDriver(
            companion: GRPCCompanionClient.makeFixture(connection: .init(host: "127.0.0.1", port: 22087)),
            simctl: simctl
        )

        try await driver.launchApp(
            appID: "com.example.app",
            arguments: [],
            environment: ["STAGE": "test", "VERBOSE": "1"]
        )

        let calls = await simctl.appCalls()
        XCTAssertEqual(
            calls,
            ["launch:booted:com.example.app:env=STAGE=test,VERBOSE=1"],
            "Environment must be forwarded to simctl (which re-exports SIMCTL_CHILD_* vars to the app)"
        )
    }

    func testConfigurationDelegatesToSimctl() async throws {
        let simctl = MockSimctlRunner()
        let driver = IOSDriver(
            companion: GRPCCompanionClient.makeFixture(connection: .init(host: "127.0.0.1", port: 22087)),
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

    func testSetTextFocusesRequestedFieldBeforeReplacingItsValue() async throws {
        let companion = MockCompanionClient()
        let driver = IOSDriver(companion: companion, simctl: MockSimctlRunner())
        try await driver.launchApp(appID: "com.example.login")

        try await driver.setText(.init(label: "Email"), text: "tester@example.com")

        let context = await companion.lastSetTextContext
        XCTAssertEqual(context?.selector.label, "Email")
        XCTAssertEqual(context?.appID, "com.example.login")
        XCTAssertEqual(context?.text, "tester@example.com")
    }

    func testSetTextResolvesDescriptionAsExactAccessibilityIdentifier() async throws {
        let companion = MockCompanionClient()
        await companion.setFindElementsResponses([
            [ElementInfo(id: "sample.auth.passwordField", label: "")]
        ])
        let driver = IOSDriver(companion: companion, simctl: MockSimctlRunner())
        try await driver.launchApp(appID: "com.example.login")

        try await driver.setText(
            .init(description: "sample.auth.passwordField"),
            text: "Password123!"
        )

        let context = await companion.lastSetTextContext
        XCTAssertEqual(context?.selector.id, "sample.auth.passwordField")
        XCTAssertNil(context?.selector.description)
        XCTAssertEqual(context?.appID, "com.example.login")
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
}
