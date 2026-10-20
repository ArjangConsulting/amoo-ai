import AmooCore
import Foundation
import MobileDevices
import ProcessRunner
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Report

struct DoctorCLIInfo: Encodable {
    var version: String
    var commit: String?
    var binary: String?
    var binaryModifiedAt: Date?

    enum CodingKeys: String, CodingKey {
        case version, commit, binary
        case binaryModifiedAt = "binary_modified_at"
    }
}

struct DoctorMCPServer: Encodable, Equatable {
    var pid: Int32
    var startedAt: Date?
    var binary: String?
    var arguments: String
    var stale: Bool

    enum CodingKeys: String, CodingKey {
        case pid, binary, arguments, stale
        case startedAt = "started_at"
    }
}

struct DoctorDevice: Encodable, Equatable {
    var platform: String
    var id: String
    var name: String?
    var os: String?
    var avd: String?
    var physical: Bool
    var runtimeID: String?

    enum CodingKeys: String, CodingKey {
        case platform, id, name, os, avd, physical
        case runtimeID = "runtime_id"
    }
}

struct DoctorCompanion: Encodable, Equatable {
    var port: Int
    var pid: Int32?
    var process: String?
    var device: String?
    var state: DeviceRuntimeState = .unresponsive
}

struct DoctorReport: Encodable {
    typealias CLI = DoctorCLIInfo
    typealias MCPServerProcess = DoctorMCPServer
    typealias Device = DoctorDevice
    typealias Companion = DoctorCompanion

    var ok: Bool
    var cli: CLI
    var mcpServers: [MCPServerProcess]
    var adbServerRunning: Bool
    var devices: [Device]
    var companions: [Companion]
    var runtimes: [DeviceRuntime]
    /// Problems that make results untrustworthy (stale servers, dead processes). `ok` is false.
    var issues: [String]
    /// Worth knowing, not a failure (e.g. a connected phone amoo will not auto-select).
    var notes: [String]

    enum CodingKeys: String, CodingKey {
        case ok, cli, devices, companions, runtimes, issues, notes
        case mcpServers = "mcp_servers"
        case adbServerRunning = "adb_server_running"
    }
}

func renderDoctorHelp() -> String {
    """
    Usage: amoo doctor [--json] [--kill-stale]

    One-shot health check for agents and humans: this CLI's build, running `amoo mcp serve`
    processes (flagging ones older than their binary), the adb server, devices (physical ones
    flagged — amoo never auto-selects them), companion listeners, and device runtimes.
    Also flags simulator runtimes (and the simulators on them) that simctl reports as unavailable.
    --kill-stale   SIGTERM every stale MCP server (one older than its binary) after reporting it.
    Exit code 0 when no issues were found, 1 otherwise.
    """
}

func handleDoctorCommand(remaining: [String]) async -> CLIResult {
    if isHelpRequest(remaining) {
        return CLIResult(output: renderDoctorHelp(), exitCode: 0)
    }
    guard remaining.allSatisfy({ $0 == "--json" || $0 == "--kill-stale" }) else {
        return CLIResult(output: renderDoctorHelp(), exitCode: 64)
    }
    var report = await runDoctor()
    if remaining.contains("--kill-stale") {
        let killed = killStaleMCPServers(report.mcpServers)
        report.notes.append(killed.isEmpty
            ? "--kill-stale: no stale MCP servers to stop."
            :
            "--kill-stale: sent SIGTERM to stale MCP server pid(s) \(killed.map(String.init).joined(separator: ", ")).")
    }
    let output = remaining.contains("--json") ? renderJSON(report) : humanDoctorSummary(report)
    return CLIResult(output: output, exitCode: report.ok ? 0 : 1)
}

func runDoctor(
    processRunner: any ProcessRunner = SystemProcessRunner(),
    store: DeviceRuntimeStore = DeviceRuntimeStore(),
    health: DeviceRuntimeHealth = DeviceRuntimeHealth()
) async -> DoctorReport {
    let build = AmooBuildInfo.current
    let runtimes = await health.observe(store.allIncludingExpired())
    let runtimeByDevice = Dictionary(runtimes.map { ($0.deviceID, $0.id) }, uniquingKeysWith: { first, _ in first })

    async let servers = mcpServerProcesses(processRunner: processRunner)
    async let adbRunning = isADBServerRunning(processRunner: processRunner)
    async let android = androidDoctorDevices(runtimeByDevice: runtimeByDevice)
    async let ios = iosDoctorDevices(runtimeByDevice: runtimeByDevice)
    async let companions = companionListeners(processRunner: processRunner)
    async let runtimeProblems = simulatorRuntimeProblems(processRunner: processRunner)

    var report = await DoctorReport(
        ok: true,
        cli: .init(
            version: build.version,
            commit: build.sourceCommit,
            binary: build.executablePath,
            binaryModifiedAt: build.binaryModifiedAt
        ),
        mcpServers: servers,
        adbServerRunning: adbRunning,
        devices: android + ios,
        companions: companions,
        runtimes: runtimes,
        issues: [],
        notes: []
    )
    report.issues = await doctorIssues(report) + runtimeProblems
    report.notes = report.devices.filter(\.physical).map { device in
        "Physical \(device.platform) device \(device.id) is connected. amoo never auto-selects it; "
            + "always pass an explicit simulator/emulator id."
    }
    report.ok = report.issues.isEmpty
    return report
}

func doctorIssues(_ report: DoctorReport) -> [String] {
    var issues: [String] = []
    for server in report.mcpServers where server.stale {
        issues.append("Stale MCP server pid \(server.pid) (\(server.binary ?? "?")): its binary was rebuilt after it "
            + "started, so it runs old code.")
    }
    if report.mcpServers.contains(where: \.stale) {
        issues.append("Run `amoo doctor --kill-stale` to stop stale MCP servers, then restart their MCP clients.")
    }
    for runtime in report.runtimes where runtime.state == .stale || runtime.state == .unresponsive {
        issues.append("Runtime on \(runtime.deviceName ?? runtime.deviceID) is \(runtime.state.rawValue); "
            + "`amoo env down --runtime-id \(runtime.id)` to clean up.")
    }
    return issues
}

func humanDoctorSummary(_ report: DoctorReport) -> String {
    var lines = ["amoo \(report.cli.version)" + (report.cli.commit.map { " (\($0))" } ?? "")]
    lines.append("MCP servers: " + (report.mcpServers.isEmpty ? "none" : report.mcpServers
            .map { "\($0.pid)\($0.stale ? " STALE" : "")" }.joined(separator: ", ")))
    lines.append("adb server: " + (report.adbServerRunning ? "running" : "not running"))
    let running = report.runtimes.filter { $0.state == .running }
    let additional = report.companions.filter { companion in
        companion.state == .running && companion.device != nil
            && !running.contains { $0.deviceID == companion.device }
    }
    let runningDevices = Set(running.map(\.deviceID) + additional.compactMap(\.device))
    lines.append("amoo running on \(runningDevices.count) device\(runningDevices.count == 1 ? "" : "s"):")
    for runtime in running {
        lines.append("  [\(runtime.platform.rawValue)] \(runtime.deviceName ?? runtime.deviceID)")
        if let port = runtime.port {
            lines.append("    Companion listening on port \(port)")
        }
    }
    for companion in additional {
        let device = report.devices.first { $0.id == companion.device }
        lines.append("  [\(device?.platform ?? "?")] \(device?.name ?? companion.device ?? "?")")
        lines.append("    Companion listening on port \(companion.port)")
    }
    let available = report.devices.filter { device in
        !runningDevices.contains(device.id)
            && !report.runtimes.contains { $0.deviceID == device.id && !$0.isExpired() }
    }
    if !available.isEmpty {
        lines.append("Other available devices:")
    }
    for device in available {
        lines.append("  [\(device.platform)] \(device.name ?? device.avd ?? device.id)")
    }
    for runtime in report.runtimes where runtime.state != .running {
        lines
            .append(
                "  [\(runtime.platform.rawValue)] \(runtime.deviceName ?? runtime.deviceID): \(runtime.state.rawValue)"
            )
    }
    lines += report.notes.map { "ℹ️ \($0)" }
    lines += report.issues.isEmpty ? ["No issues found."] : report.issues.map { "⚠️ \($0)" }
    return lines.joined(separator: "\n")
}
