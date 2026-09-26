import AmooCore
import Foundation
import ProcessRunner

// MARK: - MCP servers

struct MCPServerRow: Equatable {
    var pid: Int32
    var startedAt: Date?
    var arguments: String
}

/// `ps -axo pid=,lstart=,args=` rows that are `amoo … mcp serve`.
func parseMCPServerRows(_ psOutput: String) -> [MCPServerRow] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return psOutput.split(whereSeparator: \.isNewline).compactMap { line in
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // pid + 5 lstart fields + argv
        guard fields.count > 7, let pid = Int32(fields[0]) else { return nil }
        let argv = fields[6...]
        guard let executable = argv.first,
              URL(fileURLWithPath: executable).lastPathComponent == "amoo",
              argv.dropFirst().starts(with: ["mcp", "serve"])
        else { return nil }
        let started = formatter.date(from: fields[1 ... 5].joined(separator: " "))
        return MCPServerRow(pid: pid, startedAt: started, arguments: argv.joined(separator: " "))
    }
}

/// Executable path per pid from `lsof -a -d txt -Fpn -p …` (the first `txt` file is the binary).
func parseLsofExecutables(_ output: String) -> [Int32: String] {
    var result: [Int32: String] = [:]
    var current: Int32?
    for line in output.split(whereSeparator: \.isNewline) {
        if line.hasPrefix("p") {
            current = Int32(line.dropFirst())
        } else if line.hasPrefix("n"), let pid = current, result[pid] == nil {
            result[pid] = String(line.dropFirst())
        }
    }
    return result
}

func mcpServerProcesses(processRunner: any ProcessRunner) async -> [DoctorReport.MCPServerProcess] {
    guard let ps = try? await processRunner.run(["/bin/ps", "-axo", "pid=,lstart=,args="]) else { return [] }
    let rows = parseMCPServerRows(ps.stdout)
    guard !rows.isEmpty else { return [] }
    let pids = rows.map { String($0.pid) }.joined(separator: ",")
    let lsof = try? await processRunner.run(["/usr/sbin/lsof", "-a", "-d", "txt", "-Fpn", "-p", pids])
    let binaries = parseLsofExecutables(lsof?.stdout ?? "")
    return rows.map { row in
        let binary = binaries[row.pid]
        let modified = binary
            .flatMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
        let stale = if let modified, let started = row.startedAt {
            modified > started
        } else {
            false
        }
        return .init(pid: row.pid, startedAt: row.startedAt, binary: binary, arguments: row.arguments, stale: stale)
    }
}

// MARK: - Devices

func isADBServerRunning(processRunner: any ProcessRunner) async -> Bool {
    await (try? processRunner.run(["/usr/bin/pgrep", "-f", "adb.*fork-server"]))?.exitCode == 0
}

func androidDoctorDevices(leaseByDevice: [String: String]) async -> [DoctorReport.Device] {
    let selector = AndroidDeviceSelector()
    var devices: [DoctorReport.Device] = []
    for device in await selector.listOnlineDevices() {
        let emulator = device.serial.hasPrefix("emulator-")
        await devices.append(.init(
            platform: "android",
            id: device.serial,
            name: device.name,
            os: nil,
            avd: emulator ? selector.runningAVDName(serial: device.serial) : nil,
            physical: !emulator,
            lease: leaseByDevice[device.serial]
        ))
    }
    return devices
}

func iosDoctorDevices(leaseByDevice: [String: String]) async -> [DoctorReport.Device] {
    #if os(macOS)
    await DeviceSelector().listBootedDevices().map { device in
        .init(
            platform: "ios",
            id: device.udid,
            name: device.name,
            os: "iOS \(device.osVersion)",
            avd: nil,
            physical: device.isPhysicalDevice,
            lease: leaseByDevice[device.udid]
        )
    }
    #else
    []
    #endif
}

// MARK: - Companions

/// `lsof -nP -iTCP -sTCP:LISTEN -Fpcn` records → listeners on amoo's companion port range.
func parseCompanionListeners(_ output: String, ports: ClosedRange<Int>) -> [DoctorReport.Companion] {
    var result: [DoctorReport.Companion] = []
    var pid: Int32?
    var command: String?
    for line in output.split(whereSeparator: \.isNewline) {
        switch line.first {
        case "p": pid = Int32(line.dropFirst())
        case "c": command = String(line.dropFirst())
        case "n":
            guard let port = line.split(separator: ":").last.flatMap({ Int($0) }), ports.contains(port),
                  !result.contains(where: { $0.port == port })
            else { continue }
            result.append(.init(port: port, pid: pid, process: command, device: nil))
        default: continue
        }
    }
    return result.sorted { $0.port < $1.port }
}

func companionListeners(processRunner: any ProcessRunner) async -> [DoctorReport.Companion] {
    guard let lsof = try? await processRunner.run(["/usr/sbin/lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"])
    else { return [] }
    var listeners = parseCompanionListeners(lsof.stdout, ports: 22080 ... 22199)
    let forwards = await (try? processRunner.run(["adb", "forward", "--list"]))?.stdout ?? ""
    for index in listeners.indices {
        let port = listeners[index].port
        if let serial = forwards.split(whereSeparator: \.isNewline)
            .map({ $0.split(separator: " ").map(String.init) })
            .first(where: { $0.count == 3 && $0[1] == "tcp:\(port)" })?[0] {
            listeners[index].device = serial
        } else {
            listeners[index].device = await companionSimulatorUDID(port: port, processRunner: processRunner)
        }
    }
    return listeners
}
