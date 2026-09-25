import AmooCore
import AndroidDriver
import XCTest

extension AndroidDriverTests {
    func testBootNamedAVDDoesNotReturnAnExistingPhoneOrEmulator() async throws {
        let adb = MockADBRunner()
        let existing = "List of devices attached\nphone\tdevice\nemulator-5554\tdevice\n"
        await adb.setDeviceOutputs([existing, existing + "emulator-5556\tdevice\n"])
        let emulator = MockEmulatorRunner()
        let driver = AndroidDriver(
            companion: MockCompanionClient(), adb: adb, emulator: emulator, serial: "Requested_AVD"
        )
        try await driver.boot()
        let launches = await emulator.launches
        let info = try await driver.deviceInfo()
        let commands = await adb.rawCommands()
        XCTAssertEqual(launches, ["Requested_AVD:5556"])
        XCTAssertEqual(info.id, "emulator-5556")
        XCTAssertTrue(commands.contains(["-s", "emulator-5556", "shell", "getprop", "sys.boot_completed"]))
    }

    /// Regression: `device_boot` with no device picked the first adb device — a wireless-adb Pixel.
    func testBootWithoutADevicePrefersTheEmulatorOverAPhone() async throws {
        let adb = MockADBRunner()
        await adb
            .setDeviceOutputs(
                ["List of devices attached\nadb-PIXEL._adb-tls-connect._tcp\tdevice\nemulator-5554\tdevice\n"]
            )
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)
        try await driver.boot()
        let info = try await driver.deviceInfo()
        XCTAssertEqual(info.id, "emulator-5554")
    }

    func testBootWithoutADeviceRefusesToAutoSelectAPhone() async {
        let adb = MockADBRunner()
        await adb.setDeviceOutputs(["List of devices attached\nadb-PIXEL._adb-tls-connect._tcp\tdevice\n"])
        let emulator = MockEmulatorRunner()
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb, emulator: emulator)
        do {
            try await driver.boot()
            XCTFail("expected boot to refuse a physical-only device list")
        } catch {
            XCTAssertTrue("\(error)".contains("never auto-selects a physical device"), "\(error)")
        }
        let launches = await emulator.launches
        XCTAssertEqual(launches, [])
    }

    /// Launching a second instance of a running AVD fails on its lock; reuse the running one.
    func testBootNamedAVDReusesItsRunningEmulator() async throws {
        let adb = MockADBRunner()
        await adb.setDeviceOutputs(["List of devices attached\nemulator-5554\tdevice\nemulator-5556\tdevice\n"])
        await adb.setAVDName("Medium_Phone_API_35", serial: "emulator-5556")
        let emulator = MockEmulatorRunner()
        let driver = AndroidDriver(
            companion: MockCompanionClient(), adb: adb, emulator: emulator, serial: "Medium_Phone_API_35"
        )
        try await driver.boot()
        let launches = await emulator.launches
        XCTAssertEqual(launches, [])
        let info = try await driver.deviceInfo()
        XCTAssertEqual(info.id, "emulator-5556")
    }

    func testUnknownPowerDumpDoesNotClaimScreenIsOff() async throws {
        let adb = MockADBRunner()
        await adb.setDumpsysOutput("power", output: "unrecognized vendor output")
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)
        let state = try await driver.screenState()
        XCTAssertNil(state)
    }
}
