import AmooCore
import Foundation
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
    var lease: String?
}

struct DoctorCompanion: Encodable, Equatable {
    var port: Int
    var pid: Int32?
    var process: String?
    var device: String?
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
    var leases: [DeviceLease]
    /// Problems that make results untrustworthy (stale servers, dead holders). `ok` is false.
    var issues: [String]
    /// Worth knowing, not a failure (e.g. a connected phone amoo will not auto-select).
    var notes: [String]

    enum CodingKeys: String, CodingKey {
        case ok, cli, devices, companions, leases, issues, notes
        case mcpServers = "mcp_servers"
        case adbServerRunning = "adb_server_running"
    }
}

func renderDoctorHelp() -> String {
    """
    Usage: amoo doctor [--json]

    One-shot health check for agents and humans: this CLI's build, running `amoo mcp serve`
    processes (flagging ones older than their binary), the adb server, devices (physical ones
    flagged — amoo never auto-selects them), companion listeners, and device leases.
    Exit code 0 when no issues were found, 1 otherwise.
    """
}

func handleDoctorCommand(remaining: [String]) async -> CLIResult {
    if isHelpRequest(remaining) {
        return CLIResult(output: renderDoctorHelp(), exitCode: 0)
    }
    guard remaining.allSatisfy({ $0 == "--json" }) else {
        return CLIResult(output: renderDoctorHelp(), exitCode: 64)
    }
    let report = await runDoctor()
    let output = remaining.contains("--json") ? renderJSON(report) : humanDoctorSummary(report)
    return CLIResult(output: output, exitCode: report.ok ? 0 : 1)
}

func runDoctor(
    processRunner: any ProcessRunner = SystemProcessRunner(),
    store: DeviceLeaseStore = DeviceLeaseStore()
) async -> DoctorReport {
    let build = AmooBuildInfo.current
    let leases = store.all()
    let leaseByDevice = Dictionary(leases.map { ($0.deviceID, $0.id) }, uniquingKeysWith: { first, _ in first })

    async let servers = mcpServerProcesses(processRunner: processRunner)
    async let adbRunning = isADBServerRunning(processRunner: processRunner)
    async let android = androidDoctorDevices(leaseByDevice: leaseByDevice)
    async let ios = iosDoctorDevices(leaseByDevice: leaseByDevice)
    async let companions = companionListeners(processRunner: processRunner)

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
        leases: leases,
        issues: [],
        notes: []
    )
    report.issues = doctorIssues(report)
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
            + "started, so it runs old code. Restart that MCP client/server.")
    }
    for lease in report.leases where lease.holderPID.map({ kill($0, 0) != 0 }) ?? false {
        issues.append("Lease \(lease.id) on \(lease.deviceID) has a dead companion holder; "
            + "`amoo env down --lease \(lease.id)` to clean up.")
    }
    return issues
}

private func humanDoctorSummary(_ report: DoctorReport) -> String {
    var lines = ["amoo \(report.cli.version)" + (report.cli.commit.map { " (\($0))" } ?? "")]
    lines.append("MCP servers: " + (report.mcpServers.isEmpty ? "none" : report.mcpServers
            .map { "\($0.pid)\($0.stale ? " STALE" : "")" }.joined(separator: ", ")))
    lines.append("adb server: " + (report.adbServerRunning ? "running" : "not running"))
    for device in report.devices {
        let kind = device.physical ? "PHYSICAL" : (device.platform == "ios" ? "sim" : "emulator")
        lines.append("  [\(device.platform)] \(device.id) \(device.name ?? device.avd ?? "") \(kind)"
            + (device.lease.map { " leased=\($0)" } ?? ""))
    }
    for companion in report.companions {
        lines.append("  companion :\(companion.port) pid=\(companion.pid.map(String.init) ?? "?")"
            + " \(companion.device ?? companion.process ?? "")")
    }
    lines.append("Leases: \(report.leases.count)")
    lines += report.notes.map { "ℹ️ \($0)" }
    lines += report.issues.isEmpty ? ["No issues found."] : report.issues.map { "⚠️ \($0)" }
    return lines.joined(separator: "\n")
}
