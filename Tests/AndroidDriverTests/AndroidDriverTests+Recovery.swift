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

    func testUnknownPowerDumpDoesNotClaimScreenIsOff() async throws {
        let adb = MockADBRunner()
        await adb.setDumpsysOutput("power", output: "unrecognized vendor output")
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)
        let state = try await driver.screenState()
        XCTAssertNil(state)
    }
}
