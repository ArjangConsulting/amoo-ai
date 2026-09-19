import AmooCore
@testable import CLI
import ProcessRunner
import XCTest

final class DeviceRecoveryTests: XCTestCase {
    func testAndroidSelectionDoesNotProbeIOSAndPrefersEmulator() async throws {
        let runner = MockCLIProcessRunner(results: [.success(ProcessResult(
            exitCode: 0,
            stdout: "List of devices attached\nphone\tdevice model:Phone\nemulator-5554\tdevice model:Emulator\n",
            stderr: ""
        ))])
        let selected = try await PlatformDeviceSelector(processRunner: runner, interactive: false)
            .selectDevice(platform: .android)
        guard case let .android(serial, _) = selected else { return XCTFail("Expected Android") }
        XCTAssertEqual(serial, "emulator-5554")
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.first, "adb")
    }

    func testBootEmulatorHintDoesNotReturnConnectedPhone() async {
        let runner = MockCLIProcessRunner(results: [
            .success(ProcessResult(exitCode: 0, stdout: "List of devices attached\nphone\tdevice\n", stderr: "")),
            .success(ProcessResult(exitCode: 0, stdout: "", stderr: ""))
        ])
        let bootstrapper = DefaultSessionBootstrapper(
            iOSCompanionManager: CompanionManager(processRunner: runner),
            androidCompanionManager: AndroidCompanionManager(processRunner: runner),
            processRunner: runner
        )
        do {
            _ = try await bootstrapper.bootDevice(hint: "emulator", platform: .android)
            XCTFail("Must not report the phone as an emulator")
        } catch {
            XCTAssertTrue(String(describing: error).contains("No Android emulator/device or AVD"))
        }
    }

    func testBootDeviceHintSkipsRunningEmulator() async throws {
        let runner = MockCLIProcessRunner(results: [.success(ProcessResult(
            exitCode: 0,
            stdout: "List of devices attached\nemulator-5554\tdevice\nphone\tdevice\n",
            stderr: ""
        ))])
        let bootstrapper = DefaultSessionBootstrapper(
            iOSCompanionManager: CompanionManager(processRunner: runner),
            androidCompanionManager: AndroidCompanionManager(processRunner: runner),
            processRunner: runner
        )
        let device = try await bootstrapper.bootDevice(hint: "device", platform: .android)
        XCTAssertEqual(device.id, "phone")
    }
}
