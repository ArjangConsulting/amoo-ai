import Foundation
import ProcessRunner
import SwiftyShell
import XCTest

final class DeviceCtlTimeoutTests: XCTestCase {
    func testReadOnlyQueriesHaveBoundedTimeouts() async throws {
        let context = ShellContext(executor: MockExecutor { command, _ in
            XCTAssertEqual(command.timeoutOverride, 20)
            return ShellOutput(stdout: "{}", stderr: "", exitCode: 0)
        })
        let runner = DeviceCtlRunner(context: context)

        _ = try await runner.listDevices()
        _ = try await runner.listApps(device: "device-1")
        try await runner.terminate(device: "device-1", appID: "com.example.app")
    }

    func testInstallDoesNotInheritShortQueryTimeout() async throws {
        let context = ShellContext(executor: MockExecutor { command, _ in
            XCTAssertNil(command.timeoutOverride)
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        })

        try await DeviceCtlRunner(context: context).install(device: "device-1", appPath: "/tmp/App.app")
    }

    func testQueryTimeoutIsPropagatedRatherThanReportedAsEmptyDiscovery() async throws {
        let context = ShellContext(executor: MockExecutor { _, _ in
            throw ShellError.timeout(
                command: "xcrun devicectl list devices",
                duration: 20,
                partialOutput: ShellOutput(stdout: "partial", stderr: "", exitCode: 0)
            )
        })

        do {
            _ = try await DeviceCtlRunner(context: context).listDevices()
            XCTFail("Unreachable devices must surface a timeout")
        } catch let ShellError.timeout(_, duration, output) {
            XCTAssertEqual(duration, 20)
            XCTAssertEqual(output.stdout, "partial")
        }
    }
}
