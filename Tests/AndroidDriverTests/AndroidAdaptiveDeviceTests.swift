// swiftlint:disable line_length
import AmooCore
@testable import AndroidDriver
import Foundation
import TestCommons
import XCTest

final class AndroidAdaptiveDeviceTests: XCTestCase {
    func testEachPostureUsesEmulatorIDsAndVerifiesCommittedState() async throws {
        for (posture, identifier, name) in [
            (DevicePosture.closed, 1, "CLOSED"), (.halfOpened, 2, "HALF_OPENED"), (.opened, 3, "OPENED")
        ] {
            let adb = MockADBRunner()
            await adb.stubRawCommand(["emu", "posture", String(identifier)], outputs: ["OK\r\n"])
            await adb.stubRawCommand(
                ["shell", "cmd", "device_state", "state"],
                outputs: ["Committed state: DeviceState{identifier=42, name='\(name)'}"]
            )
            let driver = AndroidDriver(
                companion: MockCompanionClient(),
                adb: adb,
                emulator: MockEmulatorRunner(),
                serial: "emulator-5556"
            )
            let observed = try await driver.setPosture(posture)
            XCTAssertEqual(observed, posture)
            let commands = await adb.rawCommands()
            XCTAssertEqual(commands.first, ["-s", "emulator-5556", "emu", "posture", String(identifier)])
            XCTAssertTrue(commands.allSatisfy { Array($0.prefix(2)) == ["-s", "emulator-5556"] })
        }
    }

    func testPostureWaitsForCommittedStateInsteadOfEchoingDispatch() async throws {
        let adb = MockADBRunner()
        await adb.stubRawCommand(["emu", "posture", "2"], outputs: ["OK"])
        await adb.stubRawCommand(
            ["shell", "cmd", "device_state", "state"],
            outputs: ["Committed state: DeviceState{name='OPENED'}", "Committed state: DeviceState{name='HALF_OPENED'}"]
        )
        let driver = AndroidDriver(
            companion: MockCompanionClient(),
            adb: adb,
            emulator: MockEmulatorRunner(),
            serial: "emulator-5554"
        )
        let result = try await driver.setPosture(.halfOpened)
        XCTAssertEqual(result, .halfOpened)
        let commands = await adb.rawCommands()
        XCTAssertEqual(commands.filter { $0.last == "state" }.count, 2)
    }

    func testConsoleKODoesNotSucceedEvenWithZeroExitStatus() async throws {
        let adb = MockADBRunner()
        await adb.stubRawCommand(["emu", "posture", "1"], outputs: ["KO: Failed to set posture\r\n"])
        let driver = AndroidDriver(
            companion: MockCompanionClient(),
            adb: adb,
            emulator: MockEmulatorRunner(),
            serial: "emulator-5554"
        )
        do {
            _ = try await driver.setPosture(.closed)
            XCTFail("An unsupported console command must fail")
        } catch let AmooError.commandFailed(_, output) {
            XCTAssertTrue(output.contains("KO"))
        }
        let commands = await adb.rawCommands()
        XCTAssertEqual(commands.count, 1)
    }

    func testPhysicalDeviceIsRejectedWithoutCommands() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(
            companion: MockCompanionClient(),
            adb: adb,
            emulator: MockEmulatorRunner(),
            serial: "physical-phone"
        )
        do {
            _ = try await driver.setPosture(.closed)
            XCTFail("A physical hinge cannot be moved by the emulator console")
        } catch let AmooError.unsupportedCapability(key, _) {
            XCTAssertEqual(key, "device.posture")
        }
        let commands = await adb.rawCommands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testRequestedOrBaseStateIsNotCommittedPosture() {
        XCTAssertNil(AndroidDriver.committedPosture("Base state: DeviceState{name='OPENED'}"))
        XCTAssertNil(AndroidDriver.committedPosture("Requested state: DeviceState{name='CLOSED'}"))
        XCTAssertNil(AndroidDriver.committedPosture("Committed state: DeviceState{name='REAR_DISPLAY_MODE'}"))
    }

    func testDisplayPresetUsesAdvertisedDimensionsAndObservedDensity() async throws {
        let adb = MockADBRunner()
        let scratch = try await stubProfile(adb: adb, config: "hw.resizable.configs=tablet-2-1920-1200-240")
        defer { try? scratch.remove() }
        await adb.stubRawCommand(["emu", "resize-display", "2"], outputs: ["OK"])
        await adb.failRawCommand(["shell", "dumpsys", "display"], times: 1)
        await adb.stubRawCommand(
            ["shell", "dumpsys", "display"],
            outputs: [
                "mOverrideDisplayInfo=DisplayInfo{displayId 0, real 1920 x 1200, state ON, density 240 (240.0 x 240.0) dpi}"
            ]
        )
        let driver = AndroidDriver(
            companion: MockCompanionClient(),
            adb: adb,
            emulator: MockEmulatorRunner(),
            serial: "emulator-5556"
        )
        let display = try await driver.setDisplayPreset(.tablet)
        XCTAssertEqual(display, DeviceDisplayConfiguration(widthPixels: 1920, heightPixels: 1200, densityDPI: 240))
        let commands = await adb.rawCommands()
        XCTAssertTrue(commands.contains(["-s", "emulator-5556", "emu", "resize-display", "2"]))
        XCTAssertEqual(commands.filter { $0.last == "display" }.count, 2)
        XCTAssertEqual(commands.filter { $0.contains("resize-display") }.count, 1)
    }

    func testMissingDisplayPresetFailsBeforeMutation() async throws {
        let adb = MockADBRunner()
        let scratch = try await stubProfile(adb: adb, config: "hw.lcd.width=1080")
        defer { try? scratch.remove() }
        let driver = AndroidDriver(
            companion: MockCompanionClient(),
            adb: adb,
            emulator: MockEmulatorRunner(),
            serial: "emulator-5554"
        )
        do {
            _ = try await driver.setDisplayPreset(.tablet)
            XCTFail("A missing preset must not be guessed")
        } catch let AmooError.unsupportedCapability(key, _) {
            XCTAssertEqual(key, "device.displayPreset")
        }
        let commands = await adb.rawCommands()
        XCTAssertEqual(commands.count, 1)
    }

    func testIgnoredDisplayPresetIsReappliedUntilItsDimensionsMatch() async throws {
        let adb = MockADBRunner()
        let scratch = try await stubProfile(adb: adb, config: "hw.resizable.configs=tablet-2-1920-1200-240")
        defer { try? scratch.remove() }
        await adb.stubRawCommand(["emu", "resize-display", "2"], outputs: ["OK"])
        let previous = "mOverrideDisplayInfo=DisplayInfo{displayId 0, real 1080 x 2400, density 420}"
        let expected = "mOverrideDisplayInfo=DisplayInfo{displayId 0, real 1920 x 1200, density 240}"
        await adb.stubRawCommand(
            ["shell", "dumpsys", "display"],
            outputs: Array(repeating: previous, count: 12) + [expected]
        )
        let driver = AndroidDriver(
            companion: MockCompanionClient(),
            adb: adb,
            emulator: MockEmulatorRunner(),
            serial: "emulator-5556"
        )
        let display = try await driver.setDisplayPreset(.tablet)
        XCTAssertEqual(display, DeviceDisplayConfiguration(widthPixels: 1920, heightPixels: 1200, densityDPI: 240))
        let commands = await adb.rawCommands()
        XCTAssertEqual(commands.filter { $0.contains("resize-display") }.count, 2)
    }

    func testReadBackUsesActiveDisplayInsteadOfDefaultModeAndOtherDisplays() {
        XCTAssertEqual(
            AndroidDriver.activeDisplayConfiguration(
                """
                mBaseDisplayInfo=DisplayInfo{displayId 0, real 1920 x 1200, state ON, density 420 (240.0 x 240.0) dpi}
                mOverrideDisplayInfo=DisplayInfo{displayId 3, real 1080 x 2092, state OFF, density 420 (420.0 x 420.0) dpi}
                mOverrideDisplayInfo=DisplayInfo{displayId 0, real 1200 x 1920, defaultMode 3, supportedModes [{width=1080}], state ON, density 240 (240.0 x 240.0) dpi}
                """
            ),
            DeviceDisplayConfiguration(widthPixels: 1200, heightPixels: 1920, densityDPI: 240)
        )
        XCTAssertNil(AndroidDriver.activeDisplayConfiguration(
            "mOverrideDisplayInfo=DisplayInfo{displayId 0, real 0 x 1200, state ON, density 240}"
        ))
        XCTAssertEqual(
            AndroidDriver.activeDisplayConfiguration(
                "mOverrideDisplayInfo=DisplayInfo{displayId 0, real 1920 x 1200, state OFF, density 240}"
            ),
            DeviceDisplayConfiguration(widthPixels: 1920, heightPixels: 1200, densityDPI: 240)
        )
    }

    func testPresetDimensionsComeFromAVDProfileInsteadOfConsoleHelpExamples() {
        let config = "hw.resizable.configs=phone-0-1080-2400-420, foldable-1-2208-1840-420, tablet-2-1920-1200-240"
        XCTAssertEqual(
            AndroidDriver.displayPresetConfiguration(config, identifier: 1),
            DeviceDisplayConfiguration(widthPixels: 2208, heightPixels: 1840, densityDPI: 420)
        )
        XCTAssertNil(AndroidDriver.displayPresetConfiguration("2: tablet size, 1920-1200-240", identifier: 2))
        XCTAssertNil(AndroidDriver.displayPresetConfiguration(
            "hw.resizable.configs=tablet-2-0-1200-240",
            identifier: 2
        ))
    }

    private func stubProfile(adb: MockADBRunner, config: String) async throws -> TemporaryDirectory {
        let scratch = try TemporaryDirectory()
        try config.write(to: scratch.url.appendingPathComponent("hardware-qemu.ini"), atomically: true, encoding: .utf8)
        await adb.stubRawCommand(["emu", "avd", "path"], outputs: [scratch.url.path + "\r\nOK\r\n"])
        return scratch
    }
}

// swiftlint:enable line_length
