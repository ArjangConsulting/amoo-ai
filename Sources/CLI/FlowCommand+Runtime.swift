import AmooCore
import AmooLogging
import AmooTools
import Foundation
import ProcessRunner

private let logger = AmooLogger.forType(FlowOverrides.self)

/// Points a flow at the runtime it was given (`--runtime-id` / `AMOO_RUNTIME_ID`).
///
/// `amoo flow --runtime-id` used to take the runtime's device lease and stop there: with no
/// `--device` the iOS driver fell back to simctl's `booted`, which with several simulators booted
/// is whichever one simctl picks. Installs, uninstalls and launches then landed on another
/// session's simulator while gestures went to the runtime's companion, which itself was looked
/// for on the default port rather than the runtime's. A presented runtime now supplies the device,
/// and the port when it is that runtime's device. An explicit `--device` / `--port` still wins, and
/// the runtime replaces a device or port baked into the flow file.
func adoptPresentedRuntime(
    _ flow: inout TestFlow,
    overrides: FlowOverrides,
    store: DeviceRuntimeStore = DeviceRuntimeStore(),
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws {
    guard let presented = presentedRuntime(flag: overrides.runtimeID, environment: environment, store: store) else {
        return
    }
    guard let held = store.runtime(id: presented) else {
        throw DeviceAccessError.unknownRuntime(presented)
    }
    if let platform = Platform(rawValue: flow.platform.lowercased()), platform != held.amooPlatform {
        throw DeviceAccessError.wrongPlatform(held, requested: platform)
    }
    if overrides.deviceID == nil {
        flow.deviceID = held.deviceID
    }
    if overrides.port == nil, flow.deviceID == held.deviceID, let port = held.port {
        flow.port = port
    }
    logger.info(
        "Flow adopted runtime",
        context: "runtime=\(held.id) device=\(flow.deviceID ?? "none") port=\(flow.port.map(String.init) ?? "default")"
    )
}

/// The companion port a flow connects to, settling an iOS flow's device on the companion's
/// simulator when nothing named one.
func flowCompanionPort(
    _ flow: inout TestFlow,
    platform: Platform,
    overrides: FlowOverrides,
    resolveCompanionDevice: @Sendable (Int) async -> String? = { port in
        await companionSimulatorUDID(port: port, processRunner: SystemProcessRunner())
    }
) async throws -> Int {
    let port: Int = if platform == .android {
        try await resolveAndroidCompanionPort(deviceID: flow.deviceID, explicitPort: flow.port)
    } else if let explicit = flow.port {
        explicit
    } else if !overrides.devices.isEmpty || overrides.variables["device"] != nil, let udid = flow.deviceID {
        IOSCompanionPort.derived(forUDID: udid)
    } else {
        CompanionConfig.defaultPort
    }
    if platform == .ios {
        let requested = flow.deviceID ?? "booted"
        let owner = await resolveCompanionDevice(port)
        if case let .otherDevice(other) = CompanionOwnership(requested: requested, owner: owner) {
            throw CompanionError.launchFailed(companionMismatchMessage(port: port, requested: requested, owner: other))
        }
        if requested == "booted", let owner {
            flow.deviceID = owner
        }
    }
    return port
}

/// What `amoo flow --output-dir` writes to `report.json`: every step with its status, timing and
/// structured result, so a failed run can be read without probing the device again.
struct FlowReport: Encodable {
    var flow: String
    var platform: String
    var deviceID: String?
    var port: Int
    var amooCommit = AmooBuildInfo.current.sourceCommit
    var passed: Int
    var failed: Int
    var optionalFailed: Int
    var stopped: Bool
    var elapsedMilliseconds: Int
    var steps: [FlowStepRecord]
    var recordings: [String]
    /// `nil` when no extension said anything at `flow_end`, so the key is left out.
    var teardown: [FlowTeardownNote]?

    init(
        flow: String,
        platform: String,
        deviceID: String?,
        port: Int,
        result: FlowRunResult,
        elapsedMilliseconds: Int
    ) {
        self.flow = flow
        self.platform = platform
        self.deviceID = deviceID
        self.port = port
        passed = result.passed
        failed = result.failed
        optionalFailed = result.optionalFailed
        stopped = result.stopped
        self.elapsedMilliseconds = elapsedMilliseconds
        steps = result.steps
        recordings = result.recordings
        teardown = result.teardown.isEmpty ? nil : result.teardown
    }

    init(flow path: String, platform: Platform, flow: TestFlow, port: Int, result: FlowRunResult) {
        self.init(
            flow: path,
            platform: platform.rawValue,
            deviceID: flow.deviceID,
            port: port,
            result: result,
            elapsedMilliseconds: 0
        )
    }

    enum CodingKeys: String, CodingKey {
        case flow, platform, port, passed, failed, stopped, steps, recordings, teardown
        case deviceID = "device_id"
        case amooCommit = "amoo_commit"
        case optionalFailed = "optional_failed"
        case elapsedMilliseconds = "elapsed_ms"
    }
}

/// Writes `report`, timed from `started`, to `<directory>/report.json`.
func writeFlowReport(_ report: FlowReport, started: ContinuousClock.Instant, to directory: URL) -> String {
    var report = report
    report.elapsedMilliseconds = milliseconds(since: started)
    return writeFlowReport(report, to: directory)
}

/// Writes `report` to `<directory>/report.json` and returns the line saying where, or why not.
func writeFlowReport(_ report: FlowReport, to directory: URL) -> String {
    let url = directory.appending(path: "report.json")
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: url, options: .atomic)
        return "Report: \(url.path)"
    } catch {
        logger.error("Could not write flow report", error: error, context: "path=\(url.path)")
        return "Report not written: \(error)"
    }
}

extension FlowRunContext {
    /// The context for one run of `flow`: its `vars`, the device as `${device}`, `--output-dir` as
    /// `${output_dir}`, then `--var`.
    init(flow: TestFlow, overrides: FlowOverrides) {
        var variables = flow.vars
        variables["device"] = flow.deviceID ?? "booted"
        variables["output_dir"] = overrides.outputDirectory
        variables.merge(overrides.variables) { _, override in override }
        self.init(
            variables: variables,
            outputDirectory: overrides.outputDirectory.map { URL(fileURLWithPath: $0) },
            continueOnError: overrides.continueOnError
        )
    }
}

// MARK: - --record-video

/// Starts `--record-video`'s recording; `nil` when not asked for, else the start's result.
func startFlowRecording(
    overrides: FlowOverrides,
    context: FlowRunContext,
    executor: DriverToolExecutor
) async -> ToolResult? {
    guard overrides.recordVideo, let directory = context.outputDirectory else { return nil }
    let output = directory.appending(path: "recording.mp4")
    // amoo's own artifact name in the run's output directory, replaced on a rerun like its screenshots.
    try? FileManager.default.removeItem(at: output)
    return await executor.execute(toolName: "start_recording", arguments: ["output": output.path])
}

/// Saves every recording still running and reports it; a recording that failed fails the run.
func finishFlowRecordings(start: ToolResult?, executor: DriverToolExecutor, into result: inout FlowRunResult) async {
    if let start, start.isError {
        result.failed += 1
        result.lines.append("✗ --record-video: \(start.content)")
    }
    for outcome in await executor.stopActiveRecordings() {
        switch outcome {
        case let .success(saved):
            result.recordings.append(saved.path)
            let length = saved.recordedSeconds.map { String(format: " (%.1fs)", $0) } ?? ""
            result.lines.append("● Video saved to \(saved.path)\(length)")
        case let .failure(error):
            result.failed += 1
            result.lines.append("✗ Recording was not saved: \(error)")
        }
    }
}
