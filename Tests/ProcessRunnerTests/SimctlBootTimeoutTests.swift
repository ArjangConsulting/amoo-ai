import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell
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
            try await Command("/bin/sh")
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
    }
}
#endif
