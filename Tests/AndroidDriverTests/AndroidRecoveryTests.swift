import AmooCore
@testable import AndroidDriver
import Foundation
import ProcessRunner
import TestCommons
import XCTest

final class AndroidRecoveryTests: XCTestCase {
    func testWakeVerifiesGlobalPowerAndPreservesTheLockScreen() async throws {
        for locked in [false, true] {
            let adb = MockADBRunner()
            await adb.stubRawCommand(
                ["shell", "dumpsys", "power"],
                outputs: ["mWakefulness=Awake\nPower Groups:\n mWakefulness=Asleep"]
            )
            await adb.stubRawCommand(["shell", "dumpsys", "window"], outputs: ["isStatusBarKeyguard=\(locked)"])
            let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb, serial: "emulator-5554")
            let state = try await driver.wake()
            XCTAssertEqual(state, locked ? .locked : .on)
            let commands = await adb.rawCommands()
            XCTAssertEqual(commands.first, ["-s", "emulator-5554", "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
            XCTAssertEqual(commands.count, 5)
        }
    }

    func testWakeIgnoresADisplayThatDozesAgainBeforeTheStateHolds() async throws {
        let adb = MockADBRunner()
        await adb.stubRawCommand(
            ["shell", "dumpsys", "power"],
            outputs: ["mWakefulness=Awake", "mWakefulness=Dozing", "mWakefulness=Awake"]
        )
        await adb.stubRawCommand(["shell", "dumpsys", "window"], outputs: ["isStatusBarKeyguard=false"])
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb, serial: "emulator-5554")
        let state = try await driver.wake()
        XCTAssertEqual(state, .on)
        let powerReads = await adb.rawCommands().filter { $0.suffix(3) == ["shell", "dumpsys", "power"] }
        XCTAssertEqual(powerReads.count, 4)
    }

    func testDismissKeyguardClearsASwipeLockAndNeverTypesACredential() async throws {
        let adb = MockADBRunner()
        await adb.stubRawCommand(["shell", "dumpsys", "power"], outputs: ["mWakefulness=Awake"])
        await adb.stubRawCommand(
            ["shell", "dumpsys", "window"],
            outputs: ["isStatusBarKeyguard=true", "isStatusBarKeyguard=true", "isStatusBarKeyguard=false"]
        )
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb, serial: "emulator-5554")
        let state = try await driver.dismissKeyguard()
        XCTAssertEqual(state, .on)
        let commands = await adb.rawCommands()
        XCTAssertTrue(commands.contains(["-s", "emulator-5554", "shell", "wm", "dismiss-keyguard"]))
        XCTAssertFalse(commands.contains { $0.contains("text") || $0.contains("locksettings") })
    }

    func testDismissKeyguardLeavesASecureLockForThePerson() async throws {
        let adb = MockADBRunner()
        await adb.stubRawCommand(["shell", "dumpsys", "power"], outputs: ["mWakefulness=Awake"])
        await adb.stubRawCommand(["shell", "dumpsys", "window"], outputs: ["mKeyguardShowing=true"])
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb, serial: "emulator-5554")
        let state = try await driver.dismissKeyguard()
        XCTAssertEqual(state, .locked)
        let commands = await adb.rawCommands()
        XCTAssertFalse(commands.contains { $0.contains("text") || $0.contains("locksettings") })
    }

    func testSleepingGlobalPowerDoesNotBecomeAwakeBecauseAnotherGroupIsAwake() async throws {
        let adb = MockADBRunner()
        await adb.stubRawCommand(
            ["shell", "dumpsys", "power"],
            outputs: ["mWakefulness=Asleep\nPower Groups:\n mWakefulness=Awake"]
        )
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)
        let state = try await driver.screenState()
        XCTAssertEqual(state, .off)
    }

    func testFailedWakeDispatchIsNotReportedAsAwake() async throws {
        let adb = MockADBRunner()
        await adb.setFailingRawCommandSuffix(["shell", "input", "keyevent", "KEYCODE_WAKEUP"])
        do {
            _ = try await AndroidDriver(companion: MockCompanionClient(), adb: adb).wake()
            XCTFail("Wake must not succeed after a failed command")
        } catch let AmooError.commandFailed(command, _) {
            XCTAssertTrue(command.contains("KEYCODE_WAKEUP"))
        }
    }

    func testHealthDetectsWedgedGuestDespiteRespondingADBAndCompanion() async {
        let adb = MockADBRunner()
        await adb.setFailingRawCommandSuffix(["shell", "echo", "amoo-health"])
        let health = await AndroidDriver(companion: MockCompanionClient(), adb: adb).connectivityHealth()
        XCTAssertEqual(health.deviceTransport.status, "responded")
        XCTAssertEqual(health.companionRPC.status, "responded")
        XCTAssertEqual(health.deviceExecution?.status, "failed")
        XCTAssertEqual(health.failureScope, "device_execution")
    }

    func testBootWaitsForAnUnregisteredShuttingDownProcessBeforeRelaunch() async throws {
        let adb = MockADBRunner()
        await adb.setDeviceOutputs([
            "List of devices attached\n",
            "List of devices attached\n",
            "List of devices attached\nemulator-5554 device\n"
        ])
        let emulator = MockEmulatorRunner()
        let registration = AndroidEmulatorRegistration(
            pid: 42,
            serial: "emulator-5554",
            avdID: "Test_AVD",
            directory: URL(fileURLWithPath: "/tmp/avd")
        )
        await emulator.stubRegistrations([[registration], [registration], []])
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb, emulator: emulator, serial: "Test_AVD")
        try await driver.boot()
        let launches = await emulator.launches
        XCTAssertEqual(launches, ["Test_AVD:5554"])
    }

    func testBootUsesHostAVDIdentityWithoutQueryingAnUnresponsiveGuest() async throws {
        let adb = MockADBRunner()
        await adb.setFailingRawCommandSuffix(["shell", "getprop", "ro.boot.qemu.avd_name"])
        let emulator = MockEmulatorRunner()
        await emulator.stubRegistrations([[AndroidEmulatorRegistration(
            pid: 42,
            serial: "emulator-5554",
            avdID: "Test_AVD",
            directory: URL(fileURLWithPath: "/tmp/avd")
        )]])
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb, emulator: emulator, serial: "Test_AVD")
        try await driver.boot()
        let launches = await emulator.launches
        let commands = await adb.rawCommands()
        XCTAssertTrue(launches.isEmpty)
        XCTAssertTrue(commands.isEmpty)
    }

    func testPresetLookupUsesHostRegistrationWhenConsoleIsUnresponsive() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        try "hw.resizable.configs=tablet-2-1920-1200-240".write(
            to: scratch.url.appendingPathComponent("hardware-qemu.ini"),
            atomically: true,
            encoding: .utf8
        )
        let adb = MockADBRunner()
        await adb.setFailingRawCommandSuffix(["emu", "avd", "path"])
        await adb.stubRawCommand(["emu", "resize-display", "2"], outputs: ["OK"])
        await adb.stubRawCommand(
            ["shell", "dumpsys", "display"],
            outputs: ["mOverrideDisplayInfo=DisplayInfo{displayId 0, real 1920 x 1200, density 240}"]
        )
        let emulator = MockEmulatorRunner()
        await emulator.stubRegistrations([[AndroidEmulatorRegistration(
            pid: 42,
            serial: "emulator-5556",
            avdID: "Test_AVD",
            directory: scratch.url
        )]])
        let driver = AndroidDriver(
            companion: MockCompanionClient(),
            adb: adb,
            emulator: emulator,
            serial: "emulator-5556"
        )
        let configuration = try await driver.setDisplayPreset(.tablet)
        XCTAssertEqual(configuration.widthPixels, 1920)
        let commands = await adb.rawCommands()
        XCTAssertFalse(commands.contains { $0.suffix(3) == ["emu", "avd", "path"] })
    }
}
