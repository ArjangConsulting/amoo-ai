import AmooCore
@testable import CLI
import Foundation
import IOSDriver
import ProcessRunner
import TestCommons
import XCTest

final class MacPlatformTests: XCTestCase {
    func testMacCompanionConfigSelectsTheMacSchemeBundleAndProducts() {
        let mac = CompanionConfig(port: CompanionConfig.defaultMacPort, deviceUDID: MacHostBackend.deviceID)
        let simulator = CompanionConfig(deviceUDID: "sim")

        XCTAssertTrue(mac.isMac)
        XCTAssertEqual(mac.scheme, "AmooCompanionMac")
        XCTAssertEqual(mac.testBundle, "AmooCompanionMacUITests")
        XCTAssertEqual(mac.productPlatform, "macosx")
        XCTAssertFalse(simulator.isMac)
        XCTAssertEqual(simulator.scheme, "AmooCompanion")
        XCTAssertEqual(simulator.productPlatform, "iphonesimulator")
    }

    /// The Mac port must not collide with the iOS default, Android's per-emulator block, or the
    /// per-simulator range.
    func testMacPortIsOutsideEveryOtherCompanionRange() {
        let port = CompanionConfig.defaultMacPort
        XCTAssertNotEqual(port, CompanionConfig.defaultPort)
        XCTAssertFalse((22088 ... 22103).contains(port))
        let derived = IOSCompanionPort.derivedBase ..< IOSCompanionPort.derivedBase + IOSCompanionPort.derivedSpan
        XCTAssertFalse(derived.contains(port))
    }

    /// Both companions build into one folder; each must find only its own test run.
    func testEachPlatformFindsOnlyItsOwnTestRun() throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        for name in [
            "AmooCompanion_AmooCompanion_iphonesimulator27.2-arm64.xctestrun",
            "AmooCompanionMac_AmooCompanionMac_macosx27.2-arm64.xctestrun"
        ] {
            try Data().write(to: scratch.url.appending(path: name))
        }
        let manager = CompanionManager()
        let mac = manager.findXCTestRun(
            productsDir: scratch.url.path,
            config: CompanionConfig(deviceUDID: MacHostBackend.deviceID)
        )
        let simulator = manager.findXCTestRun(
            productsDir: scratch.url.path,
            config: CompanionConfig(deviceUDID: "sim")
        )
        let name: (String?) -> String? = { $0.map { URL(fileURLWithPath: $0).lastPathComponent } }

        XCTAssertEqual(name(mac), "AmooCompanionMac_AmooCompanionMac_macosx27.2-arm64.xctestrun")
        XCTAssertEqual(name(simulator), "AmooCompanion_AmooCompanion_iphonesimulator27.2-arm64.xctestrun")
    }

    func testMacAndIOSBuildsKeepSeparateSourceFingerprints() {
        let manager = CompanionManager()
        let mac = CompanionConfig(companionDir: "/companion", deviceUDID: MacHostBackend.deviceID)
        let simulator = CompanionConfig(companionDir: "/companion", deviceUDID: "sim")

        XCTAssertEqual(manager.fingerprintPath(config: simulator), "/companion/build/.amoo-source-fingerprint")
        XCTAssertEqual(manager.fingerprintPath(config: mac), "/companion/build/.amoo-source-fingerprint-macosx")
    }

    func testMacIsSelectedOnlyByItsOwnHints() throws {
        guard case .macos = try PlatformDeviceSelector.macDevice(hint: nil) else { return XCTFail("Expected the Mac") }
        for hint in ["mac", "MacOS", "this mac", MacHostBackend.deviceID] {
            guard case .macos = try PlatformDeviceSelector.macDevice(hint: hint) else { return XCTFail(hint) }
        }
        XCTAssertThrowsError(try PlatformDeviceSelector.macDevice(hint: "iPhone 17"))
    }

    /// Choosing `macos` never touches simctl or adb, and the Mac's id and platform carry through.
    func testExplicitMacOSSelectionProbesNoMobileTooling() async throws {
        let runner = MockCLIProcessRunner(results: [])
        let selector = PlatformDeviceSelector(processRunner: runner, interactive: false, runtimeStore: .temporary())
        let selected = try await selector.selectDevice(platform: .macos)

        XCTAssertEqual(selected.platform, .macos)
        XCTAssertEqual(selected.deviceID, MacHostBackend.deviceID)
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [])
    }

    /// The Mac appears in a device list only when asked for, so an agent listing devices without a
    /// platform is never offered the user's own desktop.
    func testDeviceListOffersTheMacOnlyForMacOS() async throws {
        let runner = MockCLIProcessRunner(results: [])
        let bootstrapper = DefaultSessionBootstrapper(
            iOSCompanionManager: CompanionManager(processRunner: runner),
            androidCompanionManager: AndroidCompanionManager(processRunner: runner),
            processRunner: runner
        )
        let mac = try await bootstrapper.listDevices(platform: .macos)

        XCTAssertEqual(mac.map(\.id), [MacHostBackend.deviceID])
        XCTAssertEqual(mac.first?.platform, .macos)
    }

    func testAutomationModeCheckPassesOnlyWhenNoPasswordIsNeeded() {
        let ready = DefaultPreflightChecker.automationModeCheck(output: """
        Automation Mode is disabled.
        This device DOES NOT REQUIRE user authentication to enable Automation Mode.
        """)
        let enabled = DefaultPreflightChecker.automationModeCheck(output: "Automation Mode is enabled.")
        let blocked = DefaultPreflightChecker.automationModeCheck(output: """
        Automation Mode is disabled.
        This device REQUIRES user authentication to enable Automation Mode.
        """)
        let missing = DefaultPreflightChecker.automationModeCheck(output: nil)

        XCTAssertEqual(ready.status, .pass)
        XCTAssertEqual(enabled.status, .pass)
        XCTAssertEqual(blocked.status, .fail)
        let command = "sudo automationmodetool enable-automationmode-without-authentication"
        XCTAssertTrue(blocked.remediation.contains(command))
        XCTAssertEqual(missing.status, .fail)
    }

    func testEnvUpRefusesToLeaseTheMac() {
        XCTAssertTrue(EnvError.macNotLeased.description.contains("only leases simulators and emulators"))
    }
}
