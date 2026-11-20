import AmooCore
@testable import IOSDriver
import XCTest

final class SimulatorDisplaySettingTests: XCTestCase {
    func testReadsBackEachSettingAfterChangingIt() async throws {
        let backend = SimulatorHostBackend(simctl: MockSimctlRunner())
        let size = try await backend.setDisplaySetting(
            device: "sim", setting: .textSize, value: "accessibility-extra-extra-extra-large"
        )
        XCTAssertEqual(size, "accessibility-extra-extra-extra-large")
        let appearance = try await backend.setDisplaySetting(device: "sim", setting: .appearance, value: "dark")
        XCTAssertEqual(appearance, "dark")
    }

    func testAnUnsupportedReadThrowsInsteadOfGuessing() async throws {
        let backend = SimulatorHostBackend(simctl: MockSimctlRunner())
        do {
            _ = try await backend.displaySetting(device: "sim", setting: .increaseContrast)
            XCTFail("simctl printed 'unsupported'; a caller must not restore a guessed value")
        } catch let AmooError.unsupportedCapability(key, _) {
            XCTAssertEqual(key, "config.increase_contrast")
        }
    }

    func testRejectsAValueIOSDoesNotAccept() async {
        let backend = SimulatorHostBackend(simctl: MockSimctlRunner())
        do {
            _ = try await backend.setDisplaySetting(device: "sim", setting: .textSize, value: "2.0")
            XCTFail("2.0 is an Android font scale, not an iOS content size")
        } catch {}
    }
}
