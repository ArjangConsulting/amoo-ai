import Foundation
@testable import ProcessRunner
import SwiftyShell
import TestCommons
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class DetachedProcessTests: XCTestCase {
    /// Regression: an emulator launched as a plain `Process` shared amoo's process group, so a
    /// harness tearing that group down killed it after boot. The child must lead its own group.
    func testSpawnedChildLeadsItsOwnProcessGroup() async throws {
        #if os(Windows)
        throw XCTSkip("POSIX only")
        #else
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let log = scratch.url.appendingPathComponent("detached.log").path

        let pid = try await DetachedProcess.spawn(["sh", "-c", "echo to-stderr >&2; exec sleep 30"], logPath: log)
        defer { _ = kill(-pid, SIGKILL) }
        XCTAssertGreaterThan(pid, 0)

        let output = try await waitUntil(
            timeout: .seconds(5),
            pollInterval: .milliseconds(100),
            operation: { (try? String(contentsOfFile: log, encoding: .utf8)) ?? "" },
            matching: { $0.contains("to-stderr") }
        )
        XCTAssertEqual(getpgid(pid), pid, "child should be its own group leader")
        XCTAssertEqual(getsid(pid), pid, "child should lead an independent session")
        XCTAssertNotEqual(getpgid(pid), getpgrp())
        XCTAssertTrue(output.contains("to-stderr"), "stderr should share the log")
        #endif
    }

    func testEmulatorLaunchUsesInjectedExecutor() async throws {
        let mock = MockExecutor()
        try await EmulatorRunner(context: ShellContext(executor: mock)).launch(avdName: "Pixel Test", port: 5556)
        let command = try XCTUnwrap(mock.recordedCommands.first)
        XCTAssertEqual(command.arguments, ["-avd", "Pixel Test", "-no-snapshot-save", "-port", "5556"])
        XCTAssertEqual(command.stdoutDestination, command.stderrDestination)
    }

    func testColdBootBypassesSnapshotsWithoutWipingAppData() async throws {
        let mock = MockExecutor()
        let runner = EmulatorRunner(context: ShellContext(executor: mock), coldBoot: true)
        try await runner.launch(avdName: "Test_AVD", port: 5556)
        let command = try XCTUnwrap(mock.recordedCommands.first)
        XCTAssertTrue(command.arguments.contains("-no-snapshot"))
        XCTAssertFalse(command.arguments.contains("-wipe-data"))
    }
}

/// The `am start` argument building and launcher parsing are covered by MobileDevices' own tests;
/// these check that `ADBRunner` wires its overloads to the right options.
final class AndroidLaunchArgumentsTests: XCTestCase {
    private func makeRunner() -> (ADBRunner, MockExecutor) {
        let mock = MockExecutor { command, _ in
            let stdout = command.arguments.contains("resolve-activity")
                ? "priority=0 preferredOrder=0\ncom.app/com.other.Main\n"
                : ""
            return ShellOutput(stdout: stdout, stderr: "", exitCode: 0)
        }
        return (ADBRunner(context: ShellContext(executor: mock)), mock)
    }

    /// The `am start` invocations, minus the `-s <serial>` prefix.
    private func amStarts(_ mock: MockExecutor) -> [[String]] {
        mock.recordedCommands.map(\.arguments)
            .filter { $0.starts(with: ["-s", "phone", "shell", "am", "start"]) }
            .map { Array($0.dropFirst(2)) }
    }

    /// Regression: Android dropped `environment` entirely, and repeated `--es arg` extras kept only
    /// the last launch argument.
    func testEnvironmentBecomesExtrasAndArgumentsSurvive() async throws {
        let (runner, mock) = makeRunner()
        try await runner.launch(
            serial: "phone", appID: "com.app", arguments: ["-a", "two words"], environment: ["K": "1"]
        )
        XCTAssertEqual(amStarts(mock), [[
            "shell", "am", "start", "--activity-clear-top", "-n", "com.app/com.other.Main",
            "--es", "K", "1", "--esa", "args", "'-a,two words'"
        ]])
        // A non-empty environment force-stops the app first, so `onCreate` sees the extras.
        XCTAssertTrue(mock.recordedCommands.map(\.arguments).contains {
            $0.contains("force-stop")
        })
    }

    func testPlainLaunchAndLaunchResettingKeepTheirClearTopSemantics() async throws {
        let (runner, mock) = makeRunner()
        try await runner.launch(serial: "phone", appID: "com.app", arguments: [])
        try await runner.launchResetting(serial: "phone", appID: "com.app")
        XCTAssertEqual(amStarts(mock), [
            ["shell", "am", "start", "-n", "com.app/com.other.Main"],
            ["shell", "am", "start", "--activity-clear-top", "-n", "com.app/com.other.Main"]
        ])
        XCTAssertFalse(mock.recordedCommands.map(\.arguments).contains { $0.contains("force-stop") })
    }
}
