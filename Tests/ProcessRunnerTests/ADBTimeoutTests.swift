import Foundation
import ProcessRunner
import SwiftyShell
import XCTest

final class ADBTimeoutTests: XCTestCase {
    func testScreenProbesRespectShortDeadline() async throws {
        let context = ShellContext(executor: MockExecutor { command, _ in
            XCTAssertEqual(command.timeoutOverride, 2)
            return ShellOutput(stdout: "mWakefulness=Awake", stderr: "", exitCode: 0)
        })
        _ = try await ADBRunner(context: context).run(["shell", "dumpsys", "power"], timeoutSeconds: 2)
    }

    func testRawQueriesAndTerminationAreBounded() async throws {
        let context = ShellContext(executor: MockExecutor { command, _ in
            XCTAssertNotNil(command.timeoutOverride)
            XCTAssertLessThanOrEqual(command.timeoutOverride ?? .infinity, 30)
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        })
        let runner = ADBRunner(context: context)
        _ = try await runner.run(["shell", "getprop", "sys.boot_completed"])
        _ = try await runner.listDevices()
        try await runner.terminate(serial: "phone", appID: "app")
    }

    func testAndroidInspectionHasBoundedDeadline() async throws {
        let context = ShellContext(executor: MockExecutor { command, _ in
            XCTAssertEqual(command.timeoutOverride, 20)
            return ShellOutput(stdout: "[]", stderr: "", exitCode: 0)
        })
        _ = try await AndroidCLIRunner(context: context).layout(device: "phone")
    }

    func testInstallAllowsLongerDeadline() async throws {
        let context = ShellContext(executor: MockExecutor { command, _ in
            XCTAssertEqual(command.timeoutOverride, 180)
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        })
        try await ADBRunner(context: context).install(apkPath: "/tmp/app.apk")
    }
}
