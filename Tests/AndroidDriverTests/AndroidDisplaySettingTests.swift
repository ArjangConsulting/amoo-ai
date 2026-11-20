import AmooCore
@testable import AndroidDriver
import XCTest

final class AndroidDisplaySettingTests: XCTestCase {
    func testParsesWhatAndroidPrintsForEachSetting() {
        XCTAssertEqual(AndroidDriver.displaySettingValue(.appearance, output: "Night mode: yes"), "dark")
        XCTAssertEqual(AndroidDriver.displaySettingValue(.appearance, output: "Night mode: no"), "light")
        XCTAssertEqual(AndroidDriver.displaySettingValue(.appearance, output: "Night mode: auto"), "auto")
        XCTAssertEqual(AndroidDriver.displaySettingValue(.textSize, output: "null"), "1.0")
        XCTAssertEqual(AndroidDriver.displaySettingValue(.textSize, output: "1.3"), "1.3")
        XCTAssertEqual(AndroidDriver.displaySettingValue(.increaseContrast, output: "null"), "disabled")
        XCTAssertEqual(AndroidDriver.displaySettingValue(.increaseContrast, output: "1"), "enabled")
        XCTAssertNil(AndroidDriver.displaySettingValue(.appearance, output: "error: no service"))
    }

    func testFontScaleIsWrittenAndReadBack() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb, serial: "emulator-5554")
        let reported = try await driver.setDisplaySetting(.textSize, to: "2")
        XCTAssertEqual(reported, "2.0")
        let stored = await adb.systemSetting("font_scale")
        XCTAssertEqual(stored, "2.0")
    }

    func testAppearanceUsesUimode() async throws {
        let adb = MockADBRunner()
        await adb.stubRawCommand(["shell", "cmd", "uimode", "night"], outputs: ["Night mode: yes\n"])
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb, serial: "emulator-5554")
        let reported = try await driver.setDisplaySetting(.appearance, to: "dark")
        XCTAssertEqual(reported, "dark")
        let commands = await adb.rawCommands()
        XCTAssertTrue(
            commands.contains(["-s", "emulator-5554", "shell", "cmd", "uimode", "night", "yes"]),
            "\(commands)"
        )
    }

    func testRejectsAFontScaleOutsideTheSupportedRange() async {
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: MockADBRunner(), serial: "emulator-5554")
        do {
            _ = try await driver.setDisplaySetting(.textSize, to: "3.5")
            XCTFail("Android clamps beyond 2.0")
        } catch {}
    }
}
