import AmooCore
@testable import AndroidDriver
import XCTest

final class AndroidKeyPressTests: XCTestCase {
    func testNamedKeyIsAKeyEvent() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)
        try await driver.pressKey(.leftArrow, modifiers: [])
        let commands = await adb.rawCommands()
        XCTAssertEqual(commands.last?.suffix(4), ["shell", "input", "keyevent", "KEYCODE_DPAD_LEFT"])
    }

    /// A chord must hold every key at once, which only `keycombination` does.
    func testChordIsAKeyCombination() async throws {
        let adb = MockADBRunner()
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: adb)
        try await driver.pressKey(.character("t"), modifiers: [.shift, .command])
        let commands = await adb.rawCommands()
        XCTAssertEqual(
            commands.last?.suffix(6),
            ["shell", "input", "keycombination", "KEYCODE_META_LEFT", "KEYCODE_SHIFT_LEFT", "KEYCODE_T"]
        )
    }

    func testUnmappableCharacterWithModifiersFails() async {
        let driver = AndroidDriver(companion: MockCompanionClient(), adb: MockADBRunner())
        do {
            try await driver.pressKey(.character("é"), modifiers: [.command])
            XCTFail("expected an error")
        } catch let AmooError.commandFailed(command, _) {
            XCTAssertEqual(command, "pressKey")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
