@testable import AmooTools
import MobileCore
@testable import ProcessRunner
import XCTest

/// A launch whose `adb … am force-stop` timed out read like a launch failure. The device had stopped
/// answering, and the message now says so and names the recovery.
final class DeviceUnresponsiveErrorTests: XCTestCase {
    func testATimedOutDeviceCommandReportsAnUnresponsiveDevice() async {
        do {
            _ = try await translatingMobileKitErrors { () async throws -> Int in
                throw MobileKitError.timedOut(
                    operation: "adb -s emulator-5554 shell am force-stop com.example",
                    seconds: 30
                )
            }
            XCTFail("expected an error")
        } catch let error as ProcessRunnerError {
            XCTAssertEqual(
                error,
                .deviceUnresponsive(operation: "adb -s emulator-5554 shell am force-stop com.example", seconds: 30)
            )
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("did not respond"), message)
            XCTAssertTrue(message.contains("env up"), message)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAVanishedEmulatorReportsADisconnectedDevice() async {
        do {
            _ = try await translatingMobileKitErrors { () async throws -> Int in
                throw MobileKitError.commandFailed(
                    command: ["adb", "-s", "emulator-5554", "shell", "cmd", "package", "resolve-activity"],
                    exitCode: 1,
                    output: "adb: device 'emulator-5554' not found"
                )
            }
            XCTFail("expected an error")
        } catch let error as ProcessRunnerError {
            guard case .deviceDisconnected = error else {
                return XCTFail("expected deviceDisconnected, got \(error)")
            }
            XCTAssertTrue(error.isDeviceFailure)
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("The device is gone: adb: device 'emulator-5554' not found"), message)
            XCTAssertTrue(message.contains("env up"), message)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testAnOrdinaryFailureStaysACommandFailure() {
        XCTAssertEqual(
            ProcessRunnerError.failed(command: "adb shell pm path x", exitCode: 1, output: "Error: package not found"),
            .nonZeroExit(command: "adb shell pm path x", exitCode: 1, stderr: "Error: package not found")
        )
        XCTAssertTrue(ProcessRunnerError.isDisconnectedDeviceOutput("adb: no devices/emulators found"))
        XCTAssertTrue(ProcessRunnerError.isDisconnectedDeviceOutput("error: device offline"))
    }

    func testAToolReplyNamesTheVanishedDeviceInsteadOfDumpingTheError() async {
        let error = ProcessRunnerError.deviceDisconnected(
            command: "adb -s emulator-5554 shell cmd package resolve-activity com.example",
            output: "adb: device 'emulator-5554' not found"
        )
        let message = await DriverToolExecutor(driver: MockDriver())
            .failureMessage(toolName: "device_launch_app", error: error, arguments: ["app_id": "com.example"])
        XCTAssertTrue(message.hasPrefix("device_launch_app failed: The device is gone"), message)
        XCTAssertFalse(message.contains("deviceDisconnected("), message)
    }
}
