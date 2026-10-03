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
        XCTAssertEqual(command.arguments, ["-avd", "Pixel Test", "-port", "5556", "-no-snapshot-save"])
        XCTAssertEqual(command.stdoutDestination, command.stderrDestination)
    }

    func testEmulatorLaunchArguments() {
        XCTAssertEqual(
            EmulatorRunner.launchArguments(avdName: "Medium_Phone_API_35", port: 5556),
            ["emulator", "-avd", "Medium_Phone_API_35", "-port", "5556", "-no-snapshot-save"]
        )
    }
}

final class AndroidLaunchArgumentsTests: XCTestCase {
    /// Regression: Android dropped `environment` entirely, and repeated `--es arg` extras kept only
    /// the last launch argument.
    func testEnvironmentBecomesExtrasAndArgumentsSurvive() {
        let command = ADBRunner.amStartArguments(
            component: "com.app/.Main",
            arguments: ["-a", "two words"],
            environment: ["UI_TEST_SKIP_ONBOARDING": "1", "API": "http://10.0.2.2:8080"]
        )
        XCTAssertEqual(command, [
            "shell", "am", "start", "--activity-clear-top", "-n", "com.app/.Main",
            "--es", "API", "http://10.0.2.2:8080",
            "--es", "UI_TEST_SKIP_ONBOARDING", "1",
            "--esa", "args", "'-a,two words'"
        ])
    }

    func testSingleArgumentKeepsTheHistoricalExtra() {
        let command = ADBRunner.amStartArguments(component: "c/.M", arguments: ["it's"], environment: [:])
        XCTAssertEqual(Array(command.suffix(3)), ["--es", "arg", "'it'\\''s'"])
    }

    /// Regression (a6e9f6c): the launcher class can live outside the applicationId package, and the
    /// resolver must filter on MAIN/LAUNCHER or it returns nothing and the `.MainActivity` guess ran.
    func testLauncherComponentOutsideApplicationIdPackage() {
        let output = "priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true\n"
            + "com.novalingo.android.qa/com.novalingo.MainActivity\n"
        XCTAssertEqual(
            ADBRunner.parseLauncherComponent(output, appID: "com.novalingo.android.qa"),
            "com.novalingo.android.qa/com.novalingo.MainActivity"
        )
    }

    func testNoLauncherMatchIsNotGuessed() {
        XCTAssertNil(ADBRunner.parseLauncherComponent("No activity found\n", appID: "com.app"))
        XCTAssertNil(ADBRunner.parseLauncherComponent(
            "android/com.android.internal.app.ResolverActivity",
            appID: "com.app"
        ))
    }

    func testResolveArgumentsFilterOnMainLauncher() {
        let args = ADBRunner.resolveLauncherArguments(appID: "com.app")
        XCTAssertTrue(args.contains("android.intent.category.LAUNCHER"))
        XCTAssertEqual(args.last, "com.app")
    }
}
