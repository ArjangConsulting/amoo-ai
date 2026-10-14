import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell
import XCTest

final class ADBTimeoutTests: XCTestCase {
    func testScreenProbesRespectShortDeadline() async throws {
        let context = ShellContext(executor: MockExecutor { command, _ in
            XCTAssertEqual(command.timeoutOverride, .seconds(2))
            return ShellOutput(stdout: "mWakefulness=Awake", stderr: "", exitCode: 0)
        })
        _ = try await ADBRunner(context: context).run(["shell", "dumpsys", "power"], timeoutSeconds: 2)
    }

    func testRawQueriesAndTerminationAreBounded() async throws {
        let context = ShellContext(executor: MockExecutor { command, _ in
            XCTAssertNotNil(command.timeoutOverride)
            XCTAssertLessThanOrEqual(try XCTUnwrap(command.timeoutOverride), .seconds(30))
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        })
        let runner = ADBRunner(context: context)
        _ = try await runner.run(["shell", "getprop", "sys.boot_completed"])
        _ = try await runner.listDevices()
        try await runner.terminate(serial: "phone", appID: "app")
    }

    func testAndroidInspectionHasBoundedDeadline() async throws {
        let context = ShellContext(executor: MockExecutor { command, _ in
            XCTAssertEqual(command.timeoutOverride, .seconds(20))
            return ShellOutput(stdout: "[]", stderr: "", exitCode: 0)
        })
        _ = try await AndroidCLIRunner(context: context).layout(device: "phone")
    }

    func testInstallAllowsLongerDeadline() async throws {
        let context = ShellContext(executor: MockExecutor { command, _ in
            XCTAssertEqual(command.timeoutOverride, .seconds(300))
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        })
        try await ADBRunner(context: context).install(serial: "phone", apkPath: "/tmp/app.apk")
    }
}

final class ADBRecordingTests: XCTestCase {
    /// The recording registry now lives in MobileDevices; its "already active" refusal must still
    /// surface as the `AmooError.commandFailed` callers saw before.
    func testSecondRecordingOnTheSameDeviceIsRefused() async throws {
        let runner = ADBRunner(context: ShellContext(executor: MockExecutor { _, _ in
            ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }))
        let serial = "emulator-\(UUID().uuidString)"
        try await runner.startRecording(serial: serial, outputPath: "/sdcard/a.mp4")
        defer { Task { try? await runner.stopRecording(serial: serial) } }

        do {
            try await runner.startRecording(serial: serial, outputPath: "/sdcard/b.mp4")
            XCTFail("expected the second recording to be refused")
        } catch let AmooError.commandFailed(command, output) {
            XCTAssertEqual(command, "adb screenrecord")
            XCTAssertTrue(output.contains("already active"), output)
        }
    }
}
