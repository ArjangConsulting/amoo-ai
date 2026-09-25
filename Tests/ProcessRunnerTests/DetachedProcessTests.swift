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
