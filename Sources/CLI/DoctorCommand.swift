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
    typealias Device = DoctorDevice
    typealias Companion = DoctorCompanion

    var ok: Bool
    var cli: CLI
    var adbServerRunning: Bool
    var devices: [Device]
    var companions: [Companion]
    var runtimes: [DeviceRuntime]
    /// Problems that make results untrustworthy (dead or unresponsive runtimes). `ok` is false.
    var issues: [String]
    /// Worth knowing, not a failure (e.g. a connected phone amoo will not auto-select).
    var notes: [String]
    /// Devices whose session lock is held, with the process holding it.
    var deviceLocks: [DoctorDeviceLock] = []

    enum CodingKeys: String, CodingKey {
        case ok, cli, devices, companions, runtimes, issues, notes
        case deviceLocks = "device_locks"
        case adbServerRunning = "adb_server_running"
    }
}

func renderDoctorHelp() -> String {
    """
    Usage: amoo doctor [--json]

    One-shot health check for agents and humans: this CLI's build, the adb server, devices
    (physical ones flagged — amoo never auto-selects them), companion listeners, and device
    runtimes. Unavailable simulator runtimes and their devices are advisory notes; they do not
    block healthy devices. Exit code 0 when no issues were found, 1 otherwise.
    """
}

func handleDoctorCommand(remaining: [String]) async -> CLIResult {
    if isHelpRequest(remaining) {
        return CLIResult(output: renderDoctorHelp(), exitCode: 0)
    }
    guard let options = DoctorOptions(arguments: remaining) else {
        return CLIResult(output: renderDoctorHelp(), exitCode: 64)
    }
    let report = await runDoctor(options: options)
    let output = options.json ? renderJSON(report) : humanDoctorSummary(report)
    return CLIResult(output: output, exitCode: report.ok ? 0 : 1)
}

func runDoctor(
    options: DoctorOptions = DoctorOptions(),
    processRunner: any ProcessRunner = SystemProcessRunner(),
    store: DeviceRuntimeStore = DeviceRuntimeStore(),
    health: DeviceRuntimeHealth = DeviceRuntimeHealth()
) async -> DoctorReport {
    let build = AmooBuildInfo.current
    let runtimes = await health.observe(store.allIncludingExpired())
    let runtimeByDevice = Dictionary(runtimes.map { ($0.deviceID, $0.id) }, uniquingKeysWith: { first, _ in first })

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
        adbServerRunning: adbRunning,
        devices: android + ios,
        companions: companions,
        runtimes: runtimes,
        issues: [],
        notes: [],
        deviceLocks: doctorDeviceLocks(store: store)
    )
    let unavailableSimulators = await runtimeProblems
    applyDoctorDiagnostics(&report, simulatorRuntimeProblems: unavailableSimulators)
    return report
}

func applyDoctorDiagnostics(_ report: inout DoctorReport, simulatorRuntimeProblems: [String]) {
    report.issues = doctorIssues(report) + doctorDeviceLockIssues(report)
    report.notes = report.devices.filter(\.physical).map { device in
        "Physical \(device.platform) device \(device.id) is connected. amoo never auto-selects it; "
            + "always pass an explicit simulator/emulator id."
    } + doctorDeviceLockNotes(report) + doctorUnresponsiveCompanionNotes(report) + simulatorRuntimeProblems
    report.ok = report.issues.isEmpty
}

func doctorIssues(_ report: DoctorReport) -> [String] {
    var issues: [String] = []
    for runtime in report.runtimes where runtime.state == .stale || runtime.state == .unresponsive {
        issues.append("Runtime on \(runtime.deviceName ?? runtime.deviceID) is \(runtime.state.rawValue); "
            + "`amoo env down --runtime-id \(runtime.id)` to clean up.")
    }
    return issues
}

func humanDoctorSummary(_ report: DoctorReport) -> String {
    var lines = ["amoo \(report.cli.version)" + (report.cli.commit.map { " (\($0))" } ?? "")]
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
