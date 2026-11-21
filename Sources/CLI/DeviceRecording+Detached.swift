// swiftlint:disable multiline_arguments
import AmooCore
import AmooLogging
import AmooTools
import CompanionProtocol
import Foundation
import ProcessRunner
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let detachedRecordingLogger = AmooLogger.forType(DetachedRecordingState.self)

// MARK: - State

/// What a detached recorder (`amoo device record-daemon`) reports, one JSON file per device.
///
/// `amoo device` runs one tool per process and the platform recorders live in the process that
/// started them, so `start_recording` launches a recorder in its own session and `stop_recording`,
/// a later process, signals it and reads the result back from this file.
struct DetachedRecordingState: Codable, Equatable {
    enum Status: String, Codable {
        case starting, recording, saved, failed
    }

    var pid: Int32
    var platform: String
    var deviceID: String
    var output: String
    var maxSeconds: Double
    var status: Status
    var savedPath: String?
    var byteCount: Int?
    var recordedSeconds: Double?
    var stoppedBy: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case pid, platform, output, status, error
        case deviceID = "device_id"
        case maxSeconds = "max_seconds"
        case savedPath = "saved_path"
        case byteCount = "byte_count"
        case recordedSeconds = "recorded_seconds"
        case stoppedBy = "stopped_by"
    }

    var isFinal: Bool {
        status == .saved || status == .failed
    }
}

/// `<runtime dir>/recordings/<device>.json`, beside the runtimes that coordinate device access.
struct DetachedRecordingStore {
    let directory: URL

    init(runtimeDirectory: URL = DeviceRuntimeStore().directory) {
        directory = runtimeDirectory.appending(path: "recordings")
    }

    func url(deviceID: String) -> URL {
        let safe = deviceID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" }
        return directory.appending(path: String(safe) + ".json")
    }

    func read(deviceID: String) -> DetachedRecordingState? {
        guard let data = try? Data(contentsOf: url(deviceID: deviceID)) else { return nil }
        return try? JSONDecoder().decode(DetachedRecordingState.self, from: data)
    }

    func write(_ state: DetachedRecordingState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url(deviceID: state.deviceID), options: .atomic)
    }

    func remove(deviceID: String) {
        try? FileManager.default.removeItem(at: url(deviceID: deviceID))
        try? FileManager.default.removeItem(at: url(deviceID: deviceID).appendingPathExtension("log"))
    }
}

/// How the recorder commands reach processes and time, so tests drive them without a device.
struct DetachedRecordingHooks: Sendable {
    var executablePath: @Sendable () -> String?
    var spawn: @Sendable (_ arguments: [String], _ logPath: String) async throws -> Int32
    var isAlive: @Sendable (_ pid: Int32) -> Bool
    var interrupt: @Sendable (_ pid: Int32) -> Void
    var pollInterval: Swift.Duration
    var startTimeout: Swift.Duration
    var stopTimeout: Swift.Duration

    static let live = Self(
        executablePath: { AmooBuildInfo.current.executablePath },
        spawn: { arguments, logPath in
            FileManager.default.createFile(atPath: logPath, contents: nil)
            return try await DetachedProcess.spawn(arguments, logPath: logPath)
        },
        isAlive: { kill($0, 0) == 0 },
        interrupt: { _ = kill($0, SIGINT) },
        pollInterval: .milliseconds(200),
        startTimeout: .seconds(30),
        stopTimeout: .seconds(60)
    )
}

// MARK: - start_recording / stop_recording from `amoo device`

/// `start_recording` / `stop_recording` for a one-call `amoo device` process.
func runDetachedRecordingTool(
    options: DeviceCommandOptions,
    store: DetachedRecordingStore = DetachedRecordingStore(),
    hooks: DetachedRecordingHooks = .live
) async -> CLIResult {
    guard let deviceID = options.deviceID, deviceID != "booted" else {
        return recordingFailure(
            options,
            code: "invalid_argument",
            message: "\(options.tool) needs a known device: pass --runtime-id from `amoo env up`, or --device <id>."
        )
    }
    do {
        let result = options.tool == "start_recording"
            ? try await startDetachedRecording(options: options, deviceID: deviceID, store: store, hooks: hooks)
            : try await stopDetachedRecording(deviceID: deviceID, store: store, hooks: hooks)
        return deviceCommandResult(
            options: options, content: result.content, isError: false, structured: result.structuredContent
        )
    } catch let error as DetachedRecordingError {
        detachedRecordingLogger.error(
            "Recording command failed", error: error, context: "feature=\(options.tool) device=\(deviceID)"
        )
        return recordingFailure(options, code: error.code, message: error.message)
    } catch {
        detachedRecordingLogger.error(
            "Recording command failed", error: error, context: "feature=\(options.tool) device=\(deviceID)"
        )
        return recordingFailure(options, code: "invalid_argument", message: "\(error)")
    }
}

struct DetachedRecordingError: Error, CustomStringConvertible {
    let code: String
    let message: String

    var description: String {
        message
    }
}

private func recordingFailure(_ options: DeviceCommandOptions, code: String, message: String) -> CLIResult {
    deviceCommandResult(
        options: options, content: message, isError: true,
        structured: .object(["code": .string(code), "retryable": .bool(false)])
    )
}

private func startDetachedRecording(
    options: DeviceCommandOptions,
    deviceID: String,
    store: DetachedRecordingStore,
    hooks: DetachedRecordingHooks
) async throws -> ToolResult {
    if let existing = store.read(deviceID: deviceID) {
        if !existing.isFinal, hooks.isAlive(existing.pid) {
            throw DetachedRecordingError(
                code: "recording_active",
                message: "A recording to \(existing.output) is already running on \(deviceID)."
                    + " Call stop_recording first."
            )
        }
        store.remove(deviceID: deviceID)
    }
    let output = try NativeVideo.validatedOutput(options.arguments["output"])
    let maxSeconds = try RecordingLimits.maxSeconds(options.arguments["max_seconds"], platform: options.platform)
    guard let executable = hooks.executablePath() else {
        throw DetachedRecordingError(code: "recording_failed", message: "Cannot locate the amoo executable.")
    }
    let stateURL = store.url(deviceID: deviceID)
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    detachedRecordingLogger.info("Starting detached recorder", context: "device=\(deviceID) max_seconds=\(maxSeconds)")
    let pid = try await hooks.spawn([
        executable, "device", "record-daemon",
        "--platform", options.platform.rawValue, "--device", deviceID, "--port", String(options.port),
        "--output", output.path, "--max-seconds", String(maxSeconds), "--state", stateURL.path
    ], stateURL.appendingPathExtension("log").path)
    let state = try await store.waitForRecorder(
        deviceID: deviceID,
        pid: pid,
        timeout: hooks.startTimeout,
        hooks: hooks
    ) {
        $0.status != .starting
    }
    guard state.status == .recording else {
        store.remove(deviceID: deviceID)
        throw DetachedRecordingError(code: "recording_failed", message: state.error ?? "The recorder did not start.")
    }
    detachedRecordingLogger.info("Detached recorder running", context: "device=\(deviceID) pid=\(pid)")
    return .success(
        "Recording to \(output.path). Call stop_recording on this runtime to save it; it stops by itself after"
            + " \(Int(maxSeconds)) seconds.",
        structuredContent: .object([
            "output": .string(output.path), "max_seconds": .double(maxSeconds), "recording": .bool(true),
            "recorder_pid": .int(Int(pid))
        ])
    )
}

/// Signals the device's recorder, or collects one `max_seconds` already ended, and returns what it saved.
private func stopDetachedRecording(
    deviceID: String,
    store: DetachedRecordingStore,
    hooks: DetachedRecordingHooks
) async throws -> ToolResult {
    guard let current = store.read(deviceID: deviceID) else {
        throw DetachedRecordingError(
            code: "no_active_recording",
            message: "No recording is running on \(deviceID). Start one with start_recording output=<path.mp4>."
        )
    }
    defer { store.remove(deviceID: deviceID) }
    if !current.isFinal {
        hooks.interrupt(current.pid)
    }
    let state = try await store.waitForRecorder(
        deviceID: deviceID, pid: current.pid, timeout: hooks.stopTimeout, hooks: hooks
    ) { $0.isFinal }
    guard state.status == .saved, let path = state.savedPath else {
        throw DetachedRecordingError(code: "recording_failed", message: state.error ?? "The recording was not saved.")
    }
    let saved = SavedVideo(path: path, byteCount: state.byteCount ?? 0, recordedSeconds: state.recordedSeconds)
    detachedRecordingLogger.info("Detached recording saved", context: "device=\(deviceID) bytes=\(saved.byteCount)")
    return saved.result(stoppedBy: state.stoppedBy)
}

/// Ends a recording `amoo env down` would otherwise leave running, keeping whatever it saved.
func stopLeftoverRecording(
    deviceID: String,
    store: DetachedRecordingStore,
    hooks: DetachedRecordingHooks = .live
) async {
    guard let state = store.read(deviceID: deviceID) else { return }
    if !state.isFinal, hooks.isAlive(state.pid) {
        detachedRecordingLogger.info("Stopping a recording left running", context: "device=\(deviceID)")
        hooks.interrupt(state.pid)
        _ = try? await store.waitForRecorder(
            deviceID: deviceID, pid: state.pid, timeout: hooks.stopTimeout, hooks: hooks
        ) { $0.isFinal }
    }
    store.remove(deviceID: deviceID)
}

extension DetachedRecordingStore {
    /// Polls the state file until `done`, the recorder exits, or `timeout` passes.
    func waitForRecorder(
        deviceID: String,
        pid: Int32,
        timeout: Swift.Duration,
        hooks: DetachedRecordingHooks,
        done: (DetachedRecordingState) -> Bool
    ) async throws -> DetachedRecordingState {
        let store = self
        let deadline = ContinuousClock.now + timeout
        while true {
            let state = store.read(deviceID: deviceID)
            if let state, done(state) {
                return state
            }
            if !hooks.isAlive(pid) {
                // The recorder writes its last state before exiting; read once more for that write.
                if let state = store.read(deviceID: deviceID), done(state) {
                    return state
                }
                throw DetachedRecordingError(
                    code: "recording_failed",
                    message: "The recorder exited without saving. Log: \(store.url(deviceID: deviceID).path).log"
                )
            }
            guard ContinuousClock.now < deadline else {
                throw DetachedRecordingError(
                    code: "timeout",
                    message: "The recorder did not answer within \(timeout)."
                        + " Log: \(store.url(deviceID: deviceID).path).log"
                )
            }
            try await Task.sleep(for: hooks.pollInterval)
        }
    }
}

// MARK: - The recorder process

/// `amoo device record-daemon`: holds one native recording until SIGINT/SIGTERM or `--max-seconds`.
func runRecordDaemon(arguments: [String]) async -> CLIResult {
    let parsed: RecordDaemonOptions
    do {
        parsed = try RecordDaemonOptions(arguments: arguments)
    } catch {
        return CLIResult(output: "\(error)", exitCode: 64)
    }
    let platform = parsed.platform
    let deviceID = parsed.deviceID
    let port = parsed.port
    let output = parsed.output
    let maxSeconds = parsed.maxSeconds
    let stateURL = parsed.stateFile
    let store = DetachedRecordingStore(stateFile: stateURL)
    var state = DetachedRecordingState(
        pid: getpid(), platform: platform.rawValue, deviceID: deviceID, output: output.path,
        maxSeconds: maxSeconds, status: .starting
    )
    let waiter = CompanionSignalWaiter()
    do {
        try store.write(state)
        let companion = try GRPCCompanionClient.makeLive(connection: CompanionConnection(host: "127.0.0.1", port: port))
        let options = DeviceCommandOptions(
            platform: platform, port: port, deviceID: deviceID, tool: "start_recording", arguments: [:]
        )
        let driver = await makeDeviceCommandDriver(options, companion: companion)
        let session = try await driver.startRecording()
        state.status = .recording
        try store.write(state)
        detachedRecordingLogger.info("Recorder started", context: "device=\(deviceID) max_seconds=\(maxSeconds)")
        let signalled = await firstOf(signal: waiter, seconds: maxSeconds)
        let path = try await driver.stopRecording(sessionID: session.id)
        let saved = try NativeVideo.save(recordingAt: path, to: output)
        await companion.shutdown()
        state.status = .saved
        state.savedPath = saved.path
        state.byteCount = saved.byteCount
        state.recordedSeconds = saved.recordedSeconds
        state.stoppedBy = signalled ? "stop_recording" : "max_seconds"
        try store.write(state)
        detachedRecordingLogger.info("Recorder saved", context: "device=\(deviceID) bytes=\(saved.byteCount)")
        return CLIResult(output: "", exitCode: 0)
    } catch {
        detachedRecordingLogger.error(
            "Recorder failed",
            error: error,
            context: "feature=record-daemon device=\(deviceID)"
        )
        state.status = .failed
        state.error = "\(error)"
        try? store.write(state)
        return CLIResult(output: "\(error)", exitCode: 1)
    }
}

/// `true` when a signal arrived first, `false` when `seconds` passed.
private func firstOf(signal waiter: CompanionSignalWaiter, seconds: Double) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await waiter.wait()
            return true
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return false
        }
        let first = await group.next() ?? false
        // The signal wait resumes only through `finish()`, which cancellation does not call.
        waiter.finish()
        group.cancelAll()
        return first
    }
}

extension DetachedRecordingStore {
    /// The store whose file for the device is `stateFile`, for the recorder the parent pointed at it.
    init(stateFile: URL) {
        directory = stateFile.deletingLastPathComponent()
    }
}

/// `amoo device record-daemon`'s flags, all required: the parent always passes every one.
struct RecordDaemonOptions {
    var platform: Platform
    var deviceID: String
    var port: Int
    var output: URL
    var maxSeconds: Double
    var stateFile: URL

    init(arguments: [String]) throws {
        var flags = EnvFlagReader(arguments)
        guard let platform = try flags.value("--platform").flatMap(Platform.init(rawValue:)),
              let deviceID = try flags.value("--device"),
              let port = try flags.int("--port"),
              let output = try flags.value("--output"),
              let maxSeconds = try flags.value("--max-seconds").flatMap(Double.init),
              let state = try flags.value("--state")
        else {
            throw EnvCommandParseError
                .usage("record-daemon needs --platform --device --port --output --max-seconds --state")
        }
        try flags.finish()
        self.platform = platform
        self.deviceID = deviceID
        self.port = port
        self.output = URL(fileURLWithPath: output)
        self.maxSeconds = maxSeconds
        stateFile = URL(fileURLWithPath: state)
    }
}

// swiftlint:enable multiline_arguments
