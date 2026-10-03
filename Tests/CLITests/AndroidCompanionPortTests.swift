@testable import CLI
import XCTest

final class AndroidCompanionPortTests: XCTestCase {
    func testEmulatorsMapToDistinctFixedPortsStartingAtTheDefault() {
        XCTAssertEqual(AndroidCompanionConfig.emulatorPort(forSerial: "emulator-5554"), 22088)
        XCTAssertEqual(AndroidCompanionConfig.emulatorPort(forSerial: "emulator-5556"), 22089)
        XCTAssertEqual(AndroidCompanionConfig.emulatorPort(forSerial: "emulator-5584"), 22103)
        XCTAssertEqual(AndroidCompanionConfig.defaultPort, 22088)
    }

    func testNonEmulatorSerialsHaveNoFixedPort() {
        for serial in ["R5CT1234ABC", "192.168.1.5:5555", "emulator-5555", "emulator-5586", "emulator-abc", ""] {
            XCTAssertNil(AndroidCompanionConfig.emulatorPort(forSerial: serial), serial)
        }
    }

    func testManagerUsesTheFixedPortForEmulators() async {
        let manager = AndroidCompanionManager()
        let first = await manager.companionPort(forSerial: "emulator-5554")
        let second = await manager.companionPort(forSerial: "emulator-5556")
        XCTAssertEqual(first, 22088)
        XCTAssertEqual(second, 22089)
    }

    func testOtherDevicesGetDistinctStablePortsAboveTheEmulatorRange() async {
        let manager = AndroidCompanionManager()
        let phone = await manager.companionPort(forSerial: "R5CT1234ABC")
        let tablet = await manager.companionPort(forSerial: "192.168.1.5:5555")
        let phoneAgain = await manager.companionPort(forSerial: "R5CT1234ABC")
        XCTAssertGreaterThanOrEqual(phone, AndroidCompanionConfig.fallbackPortBase)
        XCTAssertNotEqual(phone, tablet)
        XCTAssertEqual(phone, phoneAgain)
    }

    func testConcurrentRequestsForOneSerialAgreeOnThePort() async {
        let manager = AndroidCompanionManager()
        let ports = await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 6 {
                group.addTask { await manager.companionPort(forSerial: "R5CT1234ABC") }
            }
            return await group.reduce(into: Set<Int>()) { $0.insert($1) }
        }
        XCTAssertEqual(ports.count, 1)
    }

    func testShuttingDownAnUntrackedDeviceIsANoOp() async {
        let manager = AndroidCompanionManager()
        await manager.shutdown(serial: "emulator-5556")
        await manager.shutdown()
    }
}
