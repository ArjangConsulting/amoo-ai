import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell
import XCTest

final class ProcessDeadlineTests: XCTestCase {
    func testRealSubprocessFailurePreservesExitStatusAndOutput() async throws {
        let result = try await SystemProcessRunner().run(["/bin/sh", "-c", "printf failure >&2; exit 7"])
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stderr, "failure")
    }

    func testRealSubprocessCancellationReturnsPromptly() async throws {
        let task = Task { try await SystemProcessRunner().run(["/bin/sleep", "10"]) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled subprocess must not succeed")
        } catch ShellError.canceled {
            XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        } catch is CancellationError {
            XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        }
    }

    func testRequestDeadlineStopsRealSubprocess() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await OperationDeadline.$current.withValue(start + .milliseconds(100)) {
                try await SystemProcessRunner().run(["/bin/sleep", "10"])
            }
            XCTFail("Expected the request deadline to stop the subprocess")
        } catch ShellError.timeout {
            XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        }
    }

    func testExpiredDeadlineDoesNotLaunchCommand() async throws {
        let context = ShellContext(executor: MockExecutor { _, _ in
            XCTFail("An expired request must not launch a subprocess")
            return ShellOutput(stdout: "", stderr: "", exitCode: 0)
        })
        do {
            _ = try await OperationDeadline.$current.withValue(.now - .seconds(1)) {
                try await SystemProcessRunner(context: context).run(["printf", "unexpected"])
            }
            XCTFail("Expected an expired deadline")
        } catch is OperationDeadline.DeadlineExceeded {}
    }
}
