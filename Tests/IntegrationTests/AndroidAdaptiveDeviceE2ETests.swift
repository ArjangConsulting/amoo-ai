import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import ProcessRunner
import TestCommons
import XCTest

final class AndroidAdaptiveDeviceE2ETests: XCTestCase {
    func testFoldTransitionsAndConcurrentElementQueries() async throws {
        let (driver, companion) = try context(deviceKey: "AMOO_FOLDABLE_DEVICE", portKey: "AMOO_FOLDABLE_PORT")
        do {
            for posture in [DevicePosture.closed, .halfOpened, .opened] {
                let observed = try await driver.setPosture(posture)
                XCTAssertEqual(observed, posture)
                try await wakeEmulator(deviceKey: "AMOO_FOLDABLE_DEVICE")
                try await waitForQueryableScreen(companion)
                try await withThrowingTaskGroup(of: Int.self) { group in
                    for _ in 0 ..< 4 {
                        group.addTask {
                            try await companion.findElements(ElementSelector()).count
                        }
                    }
                    for try await count in group {
                        XCTAssertGreaterThan(count, 0, "A transition must not return an empty capture")
                    }
                }
            }
            await companion.shutdown()
        } catch {
            _ = try? await driver.setPosture(.opened)
            await companion.shutdown()
            throw error
        }
    }

    func testResizablePresetsReadBackRealDimensionsAndDensity() async throws {
        let (driver, companion) = try context(deviceKey: "AMOO_RESIZABLE_DEVICE", portKey: "AMOO_RESIZABLE_PORT")
        do {
            var configurations: [DeviceDisplayConfiguration] = []
            for preset in [DisplayPreset.tablet, .unfolded, .phone] {
                try await wakeEmulator(deviceKey: "AMOO_RESIZABLE_DEVICE")
                let display = try await driver.setDisplayPreset(preset)
                configurations.append(display)
                XCTAssertGreaterThan(display.widthPixels, 0)
                XCTAssertGreaterThan(display.heightPixels, 0)
                XCTAssertGreaterThan(display.densityDPI, 0)
                try await waitForQueryableScreen(companion)
                let elements = try await companion.findElements(ElementSelector())
                XCTAssertFalse(elements.isEmpty)
            }
            XCTAssertNotEqual(configurations[0], configurations[1])
            XCTAssertNotEqual(configurations[1], configurations[2])
            await companion.shutdown()
        } catch {
            _ = try? await driver.setDisplayPreset(.phone)
            await companion.shutdown()
            throw error
        }
    }

    private func context(deviceKey: String, portKey: String) throws -> (AndroidDriver, GRPCCompanionClient) {
        let environment = ProcessInfo.processInfo.environment
        guard let device = environment[deviceKey], let port = environment[portKey].flatMap(Int.init) else {
            throw XCTSkip(
                "Lease an emulator with amoo env up and set \(deviceKey) and \(portKey) to run this live check."
            )
        }
        let companion = try GRPCCompanionClient.makeLive(connection: CompanionConnection(host: "127.0.0.1", port: port))
        return (AndroidDriver(companion: companion, serial: device), companion)
    }

    private func wakeEmulator(deviceKey: String) async throws {
        guard let device = ProcessInfo.processInfo.environment[deviceKey] else { return }
        _ = try await ADBRunner().run(["-s", device, "shell", "input", "keyevent", "KEYCODE_WAKEUP"])
    }

    private func waitForQueryableScreen(_ companion: GRPCCompanionClient) async throws {
        _ = try await waitUntil(
            timeout: .seconds(5),
            pollInterval: .milliseconds(100),
            operation: { try? await companion.findElements(ElementSelector()) },
            matching: { $0?.isEmpty == false }
        )
    }
}
