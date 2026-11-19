import AmooCore
import AmooLogging
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

/// The simulator an iOS flow without a device drives: the one the companion on `port` runs in.
///
/// simctl's `booted` is ambiguous once several simulators are booted, so an install or launch
/// could land on a different simulator from the one the companion's gestures reach. Following the
/// companion keeps both on one device, the same way `amoo device` does. `nil` keeps `booted`, for
/// a lone simulator whose companion cannot be identified.
func flowSimulator(
    port: Int,
    resolveCompanionDevice: @Sendable (Int) async -> String? = { port in
        await companionSimulatorUDID(port: port, processRunner: SystemProcessRunner())
    }
) async -> String? {
    let owner = await resolveCompanionDevice(port)
    logger.debug("Flow device follows companion", context: "port=\(port) owner=\(owner ?? "unknown")")
    return owner
}

/// The companion port a flow connects to, settling an iOS flow's device on the companion's
/// simulator when nothing named one.
func flowCompanionPort(_ flow: inout TestFlow, platform: Platform, overrides: FlowOverrides) async throws -> Int {
    let port: Int = if platform == .android {
        try await resolveAndroidCompanionPort(deviceID: flow.deviceID, explicitPort: flow.port)
    } else if let explicit = flow.port {
        explicit
    } else if !overrides.devices.isEmpty || overrides.variables["device"] != nil, let udid = flow.deviceID {
        IOSCompanionPort.derived(forUDID: udid)
    } else {
        CompanionConfig.defaultPort
    }
    if platform == .ios, flow.deviceID == nil || flow.deviceID == "booted" {
        flow.deviceID = await flowSimulator(port: port) ?? flow.deviceID
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
        case flow, platform, port, passed, failed, stopped, steps
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
    /// The context for one run of `flow`: its `vars`, the device as `${device}`, then `--var`.
    init(flow: TestFlow, overrides: FlowOverrides) {
        var variables = flow.vars
        variables["device"] = flow.deviceID ?? "booted"
        variables.merge(overrides.variables) { _, override in override }
        self.init(
            variables: variables,
            outputDirectory: overrides.outputDirectory.map { URL(fileURLWithPath: $0) },
            defaultOnError: overrides.continueOnError ? .continue : flow.onError
        )
    }
}
