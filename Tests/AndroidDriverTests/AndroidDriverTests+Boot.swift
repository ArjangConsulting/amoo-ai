import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import ProcessRunner
import TestCommons
import XCTest

extension AndroidDriverTests {
    /// Regression: an emulator that died at launch was waited on for the full 120 s and reported as a
    /// bare timeout with no exit code, stderr or log path.
    func testBootFailsFastWithExitCodeAndLogWhenTheEmulatorDies() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let log = scratch.url.appendingPathComponent("dead-emulator.log").path
        let pid = try await DetachedProcess.spawn(["sh", "-c", "echo 'PANIC: no AVD' >&2; exit 3"], logPath: log)

        let adb = MockADBRunner()
        await adb.setDeviceOutputs(["List of devices attached\n"])
        let emulator = MockEmulatorRunner()
        await emulator.setHandle(EmulatorLaunch(pid: pid, logPath: log))
        let driver = AndroidDriver(
            companion: MockCompanionClient(),
            adb: adb,
            emulator: emulator,
            serial: "Medium_Phone_API_35"
        )

        let started = ContinuousClock.now
        do {
            try await driver.boot()
            XCTFail("expected the dead emulator to fail the boot")
        } catch {
            let message = "\(error)"
            XCTAssertTrue(message.contains("exited before it booted"), message)
            XCTAssertTrue(message.contains("PANIC: no AVD"), message)
            XCTAssertTrue(message.contains(log), message)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(15))
    }

    func testEmulatorLaunchLivenessNoticesAnExitedProcess() async throws {
        let pid = try await DetachedProcess.spawn(["sh", "-c", "exit 7"])
        let launch = EmulatorLaunch(pid: pid, logPath: nil)
        let state = try await waitUntil(
            timeout: .seconds(5),
            pollInterval: .milliseconds(100),
            operation: { launch.liveness() },
            matching: { $0 != .running }
        )
        // SwiftyShell reaps its detached child, so the status is gone; the exit itself is visible.
        guard case .exited = state else { return XCTFail("expected exited, got \(state)") }
    }
}
