import AndroidDriver
import CompanionProtocol
import Foundation
import ProcessRunner
import XCTest

final class AndroidRestartE2ETests: XCTestCase {
    func testVerifiedShutdownAllowsImmediateColdBootOfTheSameAVD() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let serial = environment["AMOO_RESTART_DEVICE"], let avd = environment["AMOO_RESTART_AVD"] else {
            throw XCTSkip(
                "Provide an owned emulator's AMOO_RESTART_DEVICE and AMOO_RESTART_AVD for restart verification."
            )
        }
        let companion = GRPCCompanionClient.makeFixture(connection: .init(host: "127.0.0.1", port: 22088))
        let driver = AndroidDriver(companion: companion, serial: serial)
        try await driver.shutdown()
        let remaining = try await AndroidEmulatorDiscovery().runningEmulators()
        XCTAssertFalse(remaining.contains { $0.serial == serial })
        let restarted = AndroidDriver(companion: companion, emulator: EmulatorRunner(coldBoot: true), serial: avd)
        do {
            try await restarted.boot()
            let device = try await restarted.deviceInfo()
            XCTAssertEqual(device.state, .booted)
            let state = try await restarted.wake()
            XCTAssertTrue(state == .on || state == .locked)
            try await restarted.shutdown()
        } catch {
            try? await restarted.shutdown()
            throw error
        }
    }
}
