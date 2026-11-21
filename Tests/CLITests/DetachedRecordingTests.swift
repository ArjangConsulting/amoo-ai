// swiftlint:disable multiline_arguments
import AmooCore
import AmooTools
@testable import CLI
import Foundation
import TestCommons
import XCTest

/// Stands in for `amoo device record-daemon`: it writes the state file the way the recorder would.
private final class FakeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var alive: Set<Int32> = []
    private(set) var spawned: [[String]] = []
    private(set) var interrupted: [Int32] = []
    let store: DetachedRecordingStore
    var startStatus = DetachedRecordingState.Status.recording

    init(store: DetachedRecordingStore) {
        self.store = store
    }

    var hooks: DetachedRecordingHooks {
        DetachedRecordingHooks(
            executablePath: { "/usr/local/bin/amoo" },
            spawn: { arguments, _ in self.spawn(arguments) },
            isAlive: { pid in self.lock.withLock { self.alive.contains(pid) } },
            interrupt: { pid in self.interrupt(pid) },
            pollInterval: .milliseconds(5),
            startTimeout: .seconds(2),
            stopTimeout: .seconds(2)
        )
    }

    private func value(after flag: String, in arguments: [String]) -> String {
        arguments.firstIndex(of: flag).map { arguments[$0 + 1] } ?? ""
    }

    private func spawn(_ arguments: [String]) -> Int32 {
        let pid: Int32 = 4242
        lock.withLock {
            spawned.append(arguments)
            alive.insert(pid)
        }
        var state = DetachedRecordingState(
            pid: pid, platform: value(after: "--platform", in: arguments),
            deviceID: value(after: "--device", in: arguments), output: value(after: "--output", in: arguments),
            maxSeconds: Double(value(after: "--max-seconds", in: arguments)) ?? 0, status: startStatus
        )
        if startStatus == .failed {
            state.error = "simctl io recordVideo failed"
            lock.withLock { _ = alive.remove(pid) }
        }
        try? store.write(state)
        return pid
    }

    private func interrupt(_ pid: Int32) {
        lock.withLock { interrupted.append(pid) }
        guard let deviceID = try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)
            .first(where: { $0.hasSuffix(".json") })?.dropLast(5),
            var state = store.read(deviceID: String(deviceID))
        else { return }
        state.status = .saved
        state.savedPath = state.output
        state.byteCount = 2048
        state.recordedSeconds = 4.9
        state.stoppedBy = "stop_recording"
        try? store.write(state)
        lock.withLock { _ = alive.remove(pid) }
    }
}

final class DetachedRecordingTests: XCTestCase {
    private func options(_ tool: String, deviceID: String? = "UDID-1", _ arguments: [String: String] = [:])
        -> DeviceCommandOptions {
        DeviceCommandOptions(
            platform: .ios,
            port: 22093,
            deviceID: deviceID,
            tool: tool,
            arguments: arguments,
            json: true
        )
    }

    private func fields(_ result: CLIResult) throws -> [String: Any] {
        let data = try XCTUnwrap(result.output.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func structured(_ result: CLIResult) throws -> [String: Any] {
        try XCTUnwrap(fields(result)["structured"] as? [String: Any])
    }

    func testStartThenStopRoundTripsThroughTheRecorder() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = DetachedRecordingStore(runtimeDirectory: scratch.url)
        let recorder = FakeRecorder(store: store)
        let output = scratch.url.appending(path: "clip.mp4").path

        let started = await runDetachedRecordingTool(
            options: options("start_recording", ["output": output]), store: store, hooks: recorder.hooks
        )
        XCTAssertEqual(started.exitCode, 0, started.output)
        XCTAssertEqual(try structured(started)["recorder_pid"] as? Int, 4242)
        let spawned = try XCTUnwrap(recorder.spawned.first)
        XCTAssertEqual(Array(spawned.prefix(3)), ["/usr/local/bin/amoo", "device", "record-daemon"])
        XCTAssertTrue(spawned.contains("300.0"), "\(spawned)")

        let stopped = await runDetachedRecordingTool(
            options: options("stop_recording"),
            store: store,
            hooks: recorder.hooks
        )
        XCTAssertEqual(stopped.exitCode, 0, stopped.output)
        let result = try structured(stopped)
        XCTAssertEqual(result["saved_path"] as? String, output)
        XCTAssertEqual(result["recorded_seconds"] as? Double, 4.9)
        XCTAssertEqual(result["stopped_by"] as? String, "stop_recording")
        XCTAssertEqual(recorder.interrupted, [4242])
        XCTAssertNil(store.read(deviceID: "UDID-1"), "a collected recording leaves no state behind")
    }

    func testARecorderThatFailsToStartReportsWhy() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = DetachedRecordingStore(runtimeDirectory: scratch.url)
        let recorder = FakeRecorder(store: store)
        recorder.startStatus = .failed

        let started = await runDetachedRecordingTool(
            options: options("start_recording", ["output": scratch.url.appending(path: "x.mp4").path]),
            store: store, hooks: recorder.hooks
        )

        XCTAssertEqual(started.exitCode, 1)
        XCTAssertTrue(started.output.contains("simctl io recordVideo failed"), started.output)
        XCTAssertNil(store.read(deviceID: "UDID-1"))
    }

    func testOneRecordingPerDeviceAndStopNeedsOne() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = DetachedRecordingStore(runtimeDirectory: scratch.url)
        let recorder = FakeRecorder(store: store)

        let none = await runDetachedRecordingTool(
            options: options("stop_recording"),
            store: store,
            hooks: recorder.hooks
        )
        XCTAssertEqual(try structured(none)["code"] as? String, "no_active_recording", none.output)
        _ = await runDetachedRecordingTool(
            options: options("start_recording", ["output": scratch.url.appending(path: "a.mp4").path]),
            store: store, hooks: recorder.hooks
        )
        let second = await runDetachedRecordingTool(
            options: options("start_recording", ["output": scratch.url.appending(path: "b.mp4").path]),
            store: store, hooks: recorder.hooks
        )
        XCTAssertEqual(try structured(second)["code"] as? String, "recording_active", second.output)
    }

    func testRecordingNeedsAKnownDevice() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = DetachedRecordingStore(runtimeDirectory: scratch.url)
        for deviceID in [nil, "booted"] {
            let result = await runDetachedRecordingTool(
                options: options("start_recording", deviceID: deviceID, ["output": "/tmp/x.mp4"]),
                store: store, hooks: FakeRecorder(store: store).hooks
            )
            XCTAssertEqual(try structured(result)["code"] as? String, "invalid_argument", result.output)
        }
    }

    func testStopCollectsARecordingMaxSecondsAlreadyEnded() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = DetachedRecordingStore(runtimeDirectory: scratch.url)
        let recorder = FakeRecorder(store: store)
        try store.write(DetachedRecordingState(
            pid: 99, platform: "ios", deviceID: "UDID-1", output: "/tmp/done.mp4", maxSeconds: 5, status: .saved,
            savedPath: "/tmp/done.mp4", byteCount: 10, recordedSeconds: 4.8, stoppedBy: "max_seconds"
        ))

        let stopped = await runDetachedRecordingTool(
            options: options("stop_recording"),
            store: store,
            hooks: recorder.hooks
        )

        XCTAssertEqual(try structured(stopped)["stopped_by"] as? String, "max_seconds", stopped.output)
        XCTAssertTrue(recorder.interrupted.isEmpty, "a finished recorder is not signalled")
    }

    func testEnvDownStopsARecordingLeftRunning() async throws {
        let scratch = try TemporaryDirectory()
        defer { try? scratch.remove() }
        let store = DetachedRecordingStore(runtimeDirectory: scratch.url)
        let recorder = FakeRecorder(store: store)
        _ = await runDetachedRecordingTool(
            options: options("start_recording", ["output": scratch.url.appending(path: "a.mp4").path]),
            store: store, hooks: recorder.hooks
        )

        await stopLeftoverRecording(deviceID: "UDID-1", store: store, hooks: recorder.hooks)

        XCTAssertEqual(recorder.interrupted, [4242])
        XCTAssertNil(store.read(deviceID: "UDID-1"))
    }

    func testStartAndStopRecordingPassPreflight() async {
        for tool in ["start_recording", "stop_recording"] {
            var args = ["--platform", "android", tool]
            if tool == "start_recording" {
                args.append("output=/tmp/amoo-start.mp4")
            }
            guard case let .success(parsed) = parseDeviceCommandOptions(args: args) else {
                return XCTFail("\(tool) did not parse")
            }
            if case let .finished(result) = await prepareDeviceCommand(parsed) {
                XCTFail("\(tool): \(result.output)")
            }
        }
    }

    func testRecordVideoFlowFlagNeedsAnOutputDirectory() async {
        let result = await CLIApp().run(args: ["flow", "x.amoo.json", "--record-video"])
        XCTAssertEqual(result.exitCode, 64)
        XCTAssertTrue(result.output.contains("--record-video saves <output-dir>/recording.mp4"), result.output)
    }
}

// swiftlint:enable multiline_arguments
