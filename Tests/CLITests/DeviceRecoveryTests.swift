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

/// Regression: an AVD-name `device_hint` resolved to a connected phone, or was passed to
/// `adb -s` as a serial.
final class AndroidHintResolutionTests: XCTestCase {
    private let online: [(serial: String, name: String)] = [
        (serial: "adb-PIXEL._adb-tls-connect._tcp", name: "Pixel 8"),
        (serial: "emulator-5554", name: "sdk gphone64 arm64")
    ]

    func testAVDNameMatchesItsRunningEmulator() {
        XCTAssertEqual(
            resolveAndroidHint(
                "medium_phone_api_35",
                online: online,
                runningAVDNames: ["emulator-5554": "Medium_Phone_API_35"],
                availableAVDs: ["Medium_Phone_API_35"]
            ),
            .running(serial: "emulator-5554", name: "Medium_Phone_API_35")
        )
    }

    func testStoppedAVDIsBootedNotTreatedAsASerial() {
        XCTAssertEqual(
            resolveAndroidHint(
                "Medium_Phone_API_35",
                online: online,
                runningAVDNames: [:],
                availableAVDs: ["Medium_Phone_API_35"]
            ),
            .bootAVD("Medium_Phone_API_35")
        )
    }

    func testPhoneMatchesOnlyByExactSerial() {
        XCTAssertEqual(
            resolveAndroidHint("Pixel 8", online: online, runningAVDNames: [:], availableAVDs: []),
            .unmatched
        )
        XCTAssertEqual(
            resolveAndroidHint(
                "adb-PIXEL._adb-tls-connect._tcp",
                online: online,
                runningAVDNames: [:],
                availableAVDs: []
            ),
            .running(serial: "adb-PIXEL._adb-tls-connect._tcp", name: "Pixel 8")
        )
    }
}
