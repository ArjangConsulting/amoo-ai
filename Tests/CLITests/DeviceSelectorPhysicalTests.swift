@testable import CLI
import Foundation
import ProcessRunner
import TestCommons
import XCTest

/// `isPhysicalDevice` answers a simulator UDID from CoreSimulator's device directories, so the
/// per-call iOS driver setup does not run `devicectl` for a simulator.
final class DeviceSelectorPhysicalTests: XCTestCase {
    private let simulatorUDID = "C342D46C-5843-4208-A51A-A75A3F03406A"

    func testASimulatorUDIDIsAnsweredWithoutDevicectl() async throws {
        let scratch = try makeScratchDirectory()
        try FileManager.default.createDirectory(
            at: scratch.url.appending(path: simulatorUDID), withIntermediateDirectories: true
        )
        let runner = MockCLIProcessRunner(results: [])
        let selector = DeviceSelector(processRunner: runner, simulatorDevicesDirectory: scratch.url)

        let physical = await selector.isPhysicalDevice(deviceID: simulatorUDID.lowercased())

        XCTAssertFalse(physical)
        let commands = await runner.recordedCommands()
        XCTAssertTrue(commands.isEmpty, "\(commands)")
    }

    func testAnUnknownIdentifierStillAsksDevicectl() async throws {
        let scratch = try makeScratchDirectory()
        let runner = MockCLIProcessRunner(results: [])
        let selector = DeviceSelector(processRunner: runner, simulatorDevicesDirectory: scratch.url)

        _ = await selector.isPhysicalDevice(deviceID: "00008110-001A2B3C3E88801E")
        _ = await selector.isPhysicalDevice(deviceID: simulatorUDID)

        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands.count, 2, "\(commands)")
        XCTAssertTrue(commands.allSatisfy { $0.contains("devicectl") }, "\(commands)")
    }
}
