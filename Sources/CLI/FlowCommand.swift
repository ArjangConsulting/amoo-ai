import AmooCore
import AndroidDriver
import CompanionProtocol
import Foundation
import IOSDriver
import MCPServer

/// A reusable device flow: the JSON a checked-in `*.amoo.json` file holds.
struct TestFlow: Codable, Equatable {
    /// What a failed step does to the rest of the run.
    enum OnError: String, Codable, Equatable {
        case stop
        case `continue`
    }

    typealias Step = FlowStep

    var platform: String
    var port: Int?
    var deviceID: String?
    /// Named values steps reference as `${name}`; the environment fills in whatever is not here.
    var vars: [String: String]
    var onError: OnError
    var steps: [Step]

    init(
        platform: String,
        port: Int? = nil,
        deviceID: String? = nil,
        vars: [String: String] = [:],
        onError: OnError = .stop,
        steps: [Step]
    ) {
        self.platform = platform
        self.port = port
        self.deviceID = deviceID
        self.vars = vars
        self.onError = onError
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey {
        case platform
        case port
        case deviceID = "device_id"
        case vars
        case onError = "on_error"
        case steps
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platform = try container.decode(String.self, forKey: .platform)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        let scalars = try container.decodeIfPresent([String: FlowScalar].self, forKey: .vars) ?? [:]
        vars = scalars.mapValues(\.text)
        onError = try container.decodeIfPresent(OnError.self, forKey: .onError) ?? .stop
        steps = try container.decode([Step].self, forKey: .steps)
    }
}

/// One step of a ``TestFlow``.
struct FlowStep: Codable, Equatable {
    var name: String?
    var tool: String
    var arguments: [String: String]
    /// `nil` inherits the flow's `on_error`.
    var onError: TestFlow.OnError?
    /// Runs the step this many times in a row (default once).
    var repeatCount: Int?

    init(
        name: String? = nil,
        tool: String,
        arguments: [String: String] = [:],
        onError: TestFlow.OnError? = nil,
        repeatCount: Int? = nil
    ) {
        self.name = name
        self.tool = tool
        self.arguments = arguments
        self.onError = onError
        self.repeatCount = repeatCount
    }

    enum CodingKeys: String, CodingKey {
        case name, tool, arguments
        case onError = "on_error"
        case repeatCount = "repeat"
    }

    /// Arguments may be written as JSON numbers and booleans (`"timeout_ms": 5000`,
    /// `"first": true`); the tools take strings, so they are normalized here once.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        tool = try container.decode(String.self, forKey: .tool)
        let scalars = try container.decodeIfPresent([String: FlowScalar].self, forKey: .arguments) ?? [:]
        arguments = scalars.mapValues(\.text)
        onError = try container.decodeIfPresent(TestFlow.OnError.self, forKey: .onError)
        repeatCount = try container.decodeIfPresent(Int.self, forKey: .repeatCount)
    }
}

/// A JSON string, number or boolean, read as the text a tool argument takes.
struct FlowScalar: Codable, Equatable {
    var text: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            text = value
        } else if let value = try? container.decode(Bool.self) {
            text = value ? "true" : "false"
        } else if let value = try? container.decode(Int.self) {
            text = String(value)
        } else if let value = try? container.decode(Double.self) {
            text = String(value)
        } else {
            throw DecodingError.typeMismatch(
                Self.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a string, number or boolean.")
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

func renderFlowHelp() -> String {
    """
    Usage: amoo flow <path.amoo.json> [--device <id>] [--port <n>] [--lease <id>]
                     [--devices <id[:port],...>] [--output-dir <dir>] [--var name=value]...
                     [--continue-on-error]

    Runs a checked-in sequence against one persistent driver connection. Argument values may
    reference ${name}: the flow's "vars", then --var overrides, then the environment, so credentials
    stay out of the file. Argument values can be JSON strings, numbers or booleans.
    Execution stops on the first failed action or assertion unless the step (or the flow) sets
    "on_error": "continue", or --continue-on-error is passed; the exit code is still 1 if any step failed.

    Flow-only steps:
      {"tool": "wait", "arguments": {"duration_ms": 500}}
      {"tool": "wait_for", "arguments": {"id": "home.title", "timeout_ms": 10000}}
      {"tool": "wait_for", "arguments": {"idle": true, "stable_ms": 500}}   first frame / end of animation
      {"tool": "screenshot", "name": "home"}      saved as <output-dir>/NN-home.png
    A step may also set "repeat": N to run N times.

    --device / --port override the file's device_id / port, so one checked-in flow runs against
    whatever `amoo env up` leased; --lease (or AMOO_LEASE) proves the lease is yours.

    --devices runs the flow on every listed device in parallel and prints a pass/fail line per
    device. Each entry is a device id with an optional :port; an iOS entry without one uses the
    port derived from its UDID (the one `amoo companion start --port` should be given). Each
    device's variables include ${device}; screenshots go to <output-dir>/<device>/.
    """
}

/// Command-line overrides for a flow file's target.
struct FlowOverrides: Equatable {
    var deviceID: String?
    var port: Int?
    var lease: String?
    var outputDirectory: String?
    var variables: [String: String] = [:]
    var continueOnError = false
    /// `--devices`: run on each of these instead of the single `--device`.
    var devices: [FlowDeviceTarget] = []
}

/// One entry of `--devices`: a device and the companion port serving it.
struct FlowDeviceTarget: Equatable {
    var deviceID: String
    var port: Int?

    /// Parses `id` or `id:port`. A device id never contains a colon, so the last one splits.
    init?(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let colon = trimmed.lastIndex(of: ":") {
            guard let port = Int(trimmed[trimmed.index(after: colon)...]), (1 ... 65535).contains(port) else {
                return nil
            }
            deviceID = String(trimmed[..<colon])
            self.port = port
        } else {
            deviceID = trimmed
            port = nil
        }
    }
}

func runFlowCommand(path: String, overrides: FlowOverrides = FlowOverrides()) async -> CLIResult {
    guard !overrides.devices.isEmpty else {
        let outcome = await runFlowOnce(path: path, overrides: overrides)
        return CLIResult(output: outcome.output, exitCode: outcome.exitCode)
    }
    return await runFlowOnDevices(path: path, overrides: overrides)
}

/// The result of one flow run, with the step counts a multi-device summary needs.
struct FlowOutcome: Equatable {
    var output: String
    var exitCode: Int32
    var passed = 0
    var failed = 0
}

/// Runs the flow once per `--devices` entry, all at the same time, and summarizes each device.
private func runFlowOnDevices(path: String, overrides: FlowOverrides) async -> CLIResult {
    let outcomes = await withTaskGroup(of: (FlowDeviceTarget, FlowOutcome).self) { group in
        for target in overrides.devices {
            group.addTask {
                var perDevice = overrides
                perDevice.devices = []
                perDevice.deviceID = target.deviceID
                perDevice.port = target.port ?? overrides.port
                perDevice.variables["device"] = target.deviceID
                if let base = overrides.outputDirectory {
                    perDevice.outputDirectory = URL(fileURLWithPath: base).appending(path: target.deviceID).path
                }
                return await (target, runFlowOnce(path: path, overrides: perDevice))
            }
        }
        var collected: [(FlowDeviceTarget, FlowOutcome)] = []
        for await entry in group {
            collected.append(entry)
        }
        return collected
    }
    let ordered = overrides.devices.compactMap { target in outcomes.first { $0.0 == target } }
    var lines: [String] = []
    for (target, outcome) in ordered {
        lines.append("== \(target.deviceID) ==")
        lines.append(outcome.output)
    }
    lines.append("")
    lines.append("Summary:")
    for (target, outcome) in ordered {
        let verdict = outcome.exitCode == 0 ? "PASS" : "FAIL"
        lines.append("  \(verdict)  \(target.deviceID)  (\(outcome.passed) passed, \(outcome.failed) failed)")
    }
    let anyFailed = ordered.contains { $0.1.exitCode != 0 }
    return CLIResult(output: lines.joined(separator: "\n"), exitCode: anyFailed ? 1 : 0)
}

private func runFlowOnce(path: String, overrides: FlowOverrides) async -> FlowOutcome {
    var openCompanion: GRPCCompanionClient?
    do {
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        var flow = try JSONDecoder().decode(TestFlow.self, from: Data(contentsOf: fileURL))
        flow.deviceID = overrides.deviceID ?? flow.deviceID
        flow.port = overrides.port ?? flow.port
        try enforceLease(deviceID: flow.deviceID, lease: presentedLease(flag: overrides.lease))
        guard let platform = Platform(rawValue: flow.platform.lowercased()) else {
            return FlowOutcome(output: "Unknown flow platform '\(flow.platform)'.", exitCode: 64)
        }
        guard !flow.steps.isEmpty else {
            return FlowOutcome(output: "Flow has no steps: \(fileURL.path)", exitCode: 64)
        }

        let port: Int = if platform == .android {
            try await resolveAndroidCompanionPort(deviceID: flow.deviceID, explicitPort: flow.port)
        } else if let explicit = flow.port {
            explicit
        } else if !overrides.devices.isEmpty || overrides.variables["device"] != nil, let udid = flow.deviceID {
            IOSCompanionPort.derived(forUDID: udid)
        } else {
            CompanionConfig.defaultPort
        }
        let companion = try GRPCCompanionClient.makeLive(
            connection: CompanionConnection(host: "127.0.0.1", port: port)
        )
        openCompanion = companion
        let driver = await makeFlowDriver(platform: platform, deviceID: flow.deviceID, companion: companion)

        var variables = flow.vars
        variables["device"] = flow.deviceID ?? "booted"
        variables.merge(overrides.variables) { _, override in override }
        let context = FlowRunContext(
            variables: variables,
            outputDirectory: overrides.outputDirectory.map { URL(fileURLWithPath: $0) },
            defaultOnError: overrides.continueOnError ? .continue : flow.onError
        )
        if overrides.continueOnError {
            flow.onError = .continue
        }
        let result = await runFlowSteps(flow, executor: DriverToolExecutor(driver: driver), context: context)

        await companion.shutdown()
        openCompanion = nil
        return FlowOutcome(
            output: result.lines.joined(separator: "\n"),
            exitCode: result.succeeded ? 0 : 1,
            passed: result.passed,
            failed: result.failed
        )
    } catch {
        if let openCompanion {
            await openCompanion.shutdown()
        }
        return FlowOutcome(output: "Flow failed: \(error)", exitCode: 1, failed: 1)
    }
}

private func makeFlowDriver(
    platform: Platform,
    deviceID: String?,
    companion: GRPCCompanionClient
) async -> any PlatformDriver {
    switch platform {
    case .ios:
        await makeIOSDriver(companion: companion, deviceID: deviceID ?? "booted")
    case .android:
        AndroidDriver(
            companion: companion,
            inspectionMode: .productionDefault(),
            serial: normalizedAndroidDeviceID(deviceID)
        )
    }
}

private func normalizedAndroidDeviceID(_ deviceID: String?) -> String? {
    guard let deviceID, !deviceID.isEmpty, deviceID != "booted" else { return nil }
    return deviceID
}

/// Parses `--devices a,b:22112` into targets, rejecting an entry that is not `id` or `id:port`.
func flowDeviceTargets(from raw: String?) throws -> [FlowDeviceTarget] {
    guard let raw else { return [] }
    return try raw.split(separator: ",").map { entry in
        guard let target = FlowDeviceTarget(parsing: String(entry)) else {
            throw EnvCommandParseError.usage("--devices entries are <id> or <id>:<port>, got '\(entry)'.")
        }
        return target
    }
}
