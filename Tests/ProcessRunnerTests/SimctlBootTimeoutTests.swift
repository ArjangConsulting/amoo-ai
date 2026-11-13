import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell
import Synchronization
import XCTest

#if os(macOS)
final class SimctlBootTimeoutTests: XCTestCase {
    func testBootWaitIsCappedEvenWithLongContextTimeout() async throws {
        for contextTimeout: Swift.Duration? in [nil, .seconds(1800)] {
            let mock = MockExecutor()
            let runner = SimctlRunner(context: ShellContext(executor: mock, defaultTimeout: contextTimeout))

            try await runner.bootStatus(device: "SIM")

            let command = try XCTUnwrap(mock.recordedCommands.first)
            XCTAssertEqual(command.arguments, ["simctl", "bootstatus", "SIM", "-b"])
            XCTAssertEqual(command.timeoutOverride, .seconds(60))
        }
    }

    func testBootWaitHonorsShorterContextTimeout() async throws {
        let mock = MockExecutor()
        let runner = SimctlRunner(context: ShellContext(executor: mock, defaultTimeout: .seconds(2)))

        try await runner.bootStatus(device: "SIM")

        XCTAssertEqual(mock.recordedCommands.first?.timeoutOverride, .seconds(2))
    }

    func testBootWaitHonorsRemainingRequestBudget() async throws {
        let mock = MockExecutor()
        let runner = SimctlRunner(context: ShellContext(executor: mock))

        try await OperationDeadline.$current.withValue(.now + .seconds(3)) {
            try await runner.bootStatus(device: "SIM")
        }

        let timeout = try XCTUnwrap(mock.recordedCommands.first?.timeoutOverride)
        XCTAssertGreaterThan(timeout, .zero)
        XCTAssertLessThanOrEqual(timeout, .seconds(3))
    }

    func testExpiredRequestDoesNotStartBoot() async throws {
        let mock = MockExecutor()
        let runner = SimctlRunner(context: ShellContext(executor: mock))

        do {
            try await OperationDeadline.$current.withValue(.now - .seconds(1)) {
                try await runner.bootStatus(device: "SIM")
            }
            XCTFail("An expired request must not start boot")
        } catch is OperationDeadline.DeadlineExceeded {}

        XCTAssertTrue(mock.recordedCommands.isEmpty)
    }

    func testStalledBootSubprocessTimesOutPromptly() async throws {
        let executor = MockExecutor { command, _ in
            // The stalled boot is restarted once: only the readiness wait stalls, not the shutdown.
            guard command.arguments.contains("bootstatus") else { return ShellOutput(exitCode: 0) }
            return try await Command("/bin/sh")
                .args(["-c", "printf booting; exec /bin/sleep 10"])
                .timeout(XCTUnwrap(command.timeoutOverride))
                .run()
        }
        let runner = SimctlRunner(context: ShellContext(executor: executor, defaultTimeout: .milliseconds(100)))
        let start = ContinuousClock.now

        do {
            try await runner.bootStatus(device: "SIM")
            XCTFail("A stalled boot must time out")
        } catch let ShellError.timeout(_, duration, output) {
            XCTAssertEqual(duration, .milliseconds(100))
            XCTAssertEqual(output.stdout, "booting")
            XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        }
        XCTAssertEqual(executor.recordedCommands.map(\.arguments), [
            ["simctl", "bootstatus", "SIM", "-b"], ["simctl", "shutdown", "SIM"], ["simctl", "bootstatus", "SIM", "-b"]
        ])
    }

    func testAWedgedSimulatorIsShutDownAndBootsOnTheSecondAttempt() async throws {
        let waits = Mutex(0)
        let executor = MockExecutor { command, _ in
            guard command.arguments.contains("bootstatus") else { return ShellOutput(exitCode: 0) }
            let attempt = waits.withLock { count -> Int in
                count += 1
                return count
            }
            return ShellOutput(
                stderr: attempt == 1 ? "launchd_sim did not respond" : "",
                exitCode: attempt == 1 ? 1 : 0
            )
        }

        try await SimulatorBootRecovery.boot("SIM", shell: ShellContext(executor: executor))

        XCTAssertEqual(executor.recordedCommands.map(\.arguments), [
            ["simctl", "boot", "SIM"], ["simctl", "bootstatus", "SIM", "-b"], ["simctl", "shutdown", "SIM"],
            ["simctl", "boot", "SIM"], ["simctl", "bootstatus", "SIM", "-b"]
        ])
        XCTAssertEqual(executor.recordedCommands[1].timeoutOverride, .seconds(300))
    }

    func testARefusedBootIsNotRetriedAndTheImplicitBootedDeviceIsNotRestarted() async throws {
        let refused = MockExecutor { _, _ in ShellOutput(stderr: "Invalid device: SIM", exitCode: 148) }
        do {
            try await SimulatorBootRecovery.boot("SIM", shell: ShellContext(executor: refused))
            XCTFail("An unknown device cannot boot")
        } catch {
            XCTAssertEqual(refused.recordedCommands.map(\.arguments), [["simctl", "boot", "SIM"]])
        }

        let failing = MockExecutor { _, _ in ShellOutput(stderr: "failed", exitCode: 1) }
        do {
            try await SimctlRunner(context: ShellContext(executor: failing)).bootStatus(device: "booted")
            XCTFail("The wait deliberately fails")
        } catch {
            XCTAssertEqual(failing.recordedCommands.map(\.arguments), [["simctl", "bootstatus", "booted", "-b"]])
        }
    }
}
#endif
