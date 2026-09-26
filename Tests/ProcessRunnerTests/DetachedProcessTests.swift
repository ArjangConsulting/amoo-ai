import Foundation
@testable import ProcessRunner
import XCTest

final class DetachedProcessTests: XCTestCase {
    /// Regression: an emulator launched as a plain `Process` shared amoo's process group, so a
    /// harness tearing that group down killed it after boot. The child must lead its own group.
    func testSpawnedChildLeadsItsOwnProcessGroup() throws {
        #if os(Windows)
        throw XCTSkip("POSIX only")
        #else
        let log = NSTemporaryDirectory() + "amoo-detached-\(UUID().uuidString).log"
        defer { try? FileManager.default.removeItem(atPath: log) }

        let pid = try DetachedProcess.spawn(["sh", "-c", "ps -o pgid= -p $$; echo to-stderr >&2"], logPath: log)
        XCTAssertGreaterThan(pid, 0)

        var output = ""
        for _ in 0 ..< 50 where !output.contains("to-stderr") {
            Thread.sleep(forTimeInterval: 0.1)
            output = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        }
        let childGroup = output.split(whereSeparator: \.isNewline).first
            .flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(childGroup, pid, "child should be its own group leader: \(output)")
        XCTAssertNotEqual(childGroup, getpgrp())
        XCTAssertTrue(output.contains("to-stderr"), "stderr should share the log")
        #endif
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
}
