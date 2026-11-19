@testable import CLI
import Foundation
import ProcessRunner
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `env down` reported "Could not stop the companion process" for a companion that ignored
/// SIGTERM: the SIGKILL was sent and the check ran before the process had gone, so only a retry
/// succeeded.
final class StopProcessTests: XCTestCase {
    func testProcessThatIgnoresSIGTERMIsGoneWhenStopReturns() async throws {
        let pid = try await DetachedProcess.spawn(["/bin/sh", "-c", "trap '' TERM; while :; do sleep 1; done"])
        XCTAssertEqual(kill(pid, 0), 0)

        stopProcess(pid: pid, graceSeconds: 0.3)

        XCTAssertNotEqual(kill(pid, 0), 0, "the caller's liveness check must see the process gone")
    }

    func testWaitReportsAProcessThatKeepsRunning() async throws {
        let pid = try await DetachedProcess.spawn(["/bin/sh", "-c", "while :; do sleep 1; done"])
        defer { stopProcess(pid: pid, graceSeconds: 0.3) }
        XCTAssertFalse(waitForProcessExit(pid, seconds: 0.2))
    }
}
