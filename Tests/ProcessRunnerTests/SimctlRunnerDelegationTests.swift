import Foundation
import ProcessRunner
import TestCommons
import XCTest

#if os(macOS)
/// `SimctlRunner` delegates to MobileDevices' `SimulatorManager`; these cover the argument mapping
/// and error translation at that boundary (macOS only, `simctl` does not exist elsewhere).
final class SimctlRunnerDelegationTests: XCTestCase {
    func testSimctlRunnerRejectsUnknownPermissionAction() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = SimctlRunner(context: mock.context)

        do {
            try await runner.setPermission(
                device: "booted", action: "allow", permission: "camera", appID: "com.example"
            )
            XCTFail("Expected an unknown permission action to throw")
        } catch let ProcessRunnerError.nonZeroExit(_, exitCode, stderr) {
            XCTAssertEqual(exitCode, 64)
            XCTAssertTrue(stderr.contains("'allow'"), stderr)
            XCTAssertTrue(stderr.contains("grant, revoke, reset"), stderr)
        }

        let commands = await mock.recordedCommands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testSimctlRunnerScreenshotRunsIOScreenshotWithFormat() async {
        let mock = MockShellExecutor(result: .init(exitCode: 0, stdout: "", stderr: ""))
        let runner = SimctlRunner(context: mock.context)

        // The mocked simctl writes no image, so the manager reports the missing file; the recorded
        // command still proves the format mapping and the `io screenshot` invocation.
        _ = try? await runner.screenshot(device: "UDID-123", format: .jpeg)

        let commands = await mock.recordedCommands()
        XCTAssertEqual(commands.count, 1)
        let command = commands.first ?? []
        XCTAssertEqual(Array(command.prefix(6)), ["xcrun", "simctl", "io", "UDID-123", "screenshot", "--type=jpeg"])
    }

    func testSimctlRunnerTranslatesFailedCaptureToProcessRunnerError() async throws {
        let mock = MockShellExecutor(result: .init(exitCode: 1, stdout: "", stderr: "no device"))
        let runner = SimctlRunner(context: mock.context)

        do {
            _ = try await runner.screenshot(device: "UDID-123")
            XCTFail("Expected a failed screenshot to throw")
        } catch let ProcessRunnerError.nonZeroExit(command, exitCode, _) {
            XCTAssertTrue(command.contains("screenshot"), command)
            XCTAssertEqual(exitCode, 1)
        }
    }
}
#endif
