import AmooCore
@testable import AmooTools
import Foundation
import TestCommons
import XCTest

final class RecordingSessionTests: XCTestCase {
    private func code(_ result: ToolResult) -> String? {
        result.structuredContent?.objectValue?["code"]?.stringValue
    }

    func testStartThenStopSavesTheVideoWithItsRealLength() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let driver = MockDriver()
        let executor = DriverToolExecutor(driver: driver, defaultPlatform: .ios)
        let output = scratch.url.appending(path: "clip.mp4").path

        let started = await executor.execute(toolName: "start_recording", arguments: ["output": output])
        XCTAssertFalse(started.isError, started.content)
        let stopped = await executor.execute(toolName: "stop_recording", arguments: [:])
        XCTAssertFalse(stopped.isError, stopped.content)

        let fields = try XCTUnwrap(stopped.structuredContent?.objectValue)
        XCTAssertEqual(fields["saved_path"]?.stringValue, output)
        XCTAssertEqual(fields["recorded_seconds"], .double(5))
        XCTAssertEqual(fields["stopped_by"]?.stringValue, "stop_recording")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output))
        let calls = await driver.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("recording:") }, ["recording:start", "recording:stop:rec"])
    }

    func testOneRecordingAtATimeAndStopNeedsOne() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let executor = DriverToolExecutor(driver: MockDriver(), defaultPlatform: .ios)

        let none = await executor.execute(toolName: "stop_recording", arguments: [:])
        XCTAssertEqual(code(none), "no_active_recording", none.content)
        _ = await executor.execute(
            toolName: "start_recording",
            arguments: ["output": scratch.url.appending(path: "a.mp4").path]
        )
        let second = await executor.execute(
            toolName: "start_recording", arguments: ["output": scratch.url.appending(path: "b.mp4").path]
        )
        XCTAssertEqual(code(second), "recording_active", second.content)
    }

    func testMaxSecondsEndsTheRecordingAndStopCollectsIt() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let output = scratch.url.appending(path: "clip.mp4").path
        let executor = DriverToolExecutor(driver: MockDriver(), defaultPlatform: .ios)

        _ = await executor.execute(toolName: "start_recording", arguments: ["output": output, "max_seconds": "1"])
        _ = try await waitUntil(timeout: .seconds(5), pollInterval: .milliseconds(50)) {
            FileManager.default.fileExists(atPath: output)
        } matching: { $0 }
        let stopped = await executor.execute(toolName: "stop_recording", arguments: [:])

        XCTAssertFalse(stopped.isError, stopped.content)
        XCTAssertEqual(stopped.structuredContent?.objectValue?["stopped_by"]?.stringValue, "max_seconds")
    }

    func testRejectsAnExistingOutputAndAndroidPastScreenrecordsLimit() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let existing = scratch.url.appending(path: "taken.mp4")
        try Data([1]).write(to: existing)
        let ios = DriverToolExecutor(driver: MockDriver(), defaultPlatform: .ios)
        let taken = await ios.execute(toolName: "start_recording", arguments: ["output": existing.path])
        XCTAssertEqual(code(taken), "invalid_argument", taken.content)

        let android = DriverToolExecutor(driver: MockDriver(), defaultPlatform: .android)
        let tooLong = await android.execute(
            toolName: "start_recording",
            arguments: ["output": scratch.url.appending(path: "long.mp4").path, "max_seconds": "200"]
        )
        XCTAssertEqual(code(tooLong), "invalid_argument", tooLong.content)
        XCTAssertTrue(tooLong.content.contains("180"), tooLong.content)
    }

    func testStopActiveRecordingsSavesWhatARunLeftRunning() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let output = scratch.url.appending(path: "left.mp4").path
        let executor = DriverToolExecutor(driver: MockDriver(), defaultPlatform: .ios)
        _ = await executor.execute(toolName: "start_recording", arguments: ["output": output])

        let outcomes = await executor.stopActiveRecordings()

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(try outcomes.first?.get().path, output)
        let again = await executor.stopActiveRecordings()
        XCTAssertTrue(again.isEmpty)
    }
}
