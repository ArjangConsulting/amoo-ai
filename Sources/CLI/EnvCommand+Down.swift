import AmooCore
import Foundation
import ProcessRunner
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct EnvDownReport: Encodable {
    var ok: Bool
    var lease: String?
    var device: String?
    var holderStopped: Bool
    var shutdown: Bool
    var error: String?

    enum CodingKeys: String, CodingKey {
        case ok, lease, device, shutdown, error
        case holderStopped = "holder_stopped"
    }
}

func runEnvDown(_ options: EnvDownOptions, store: DeviceLeaseStore = DeviceLeaseStore()) async -> CLIResult {
    var report = EnvDownReport(ok: false, holderStopped: false, shutdown: false)
    let finish: (Int32) -> CLIResult = { code in
        let human = report.ok
            ? "Released \(report.lease ?? "?") on \(report.device ?? "?")"
            + (report.shutdown ? "; device shut down." : ".")
            : "env down failed: \(report.error ?? "unknown error")"
        return CLIResult(output: options.json ? renderJSON(report) : human, exitCode: code)
    }

    let lease: DeviceLease? = if let id = options.lease {
        store.lease(id: id)
    } else {
        options.deviceID.flatMap { store.lease(forDevice: $0) }
    }
    guard let lease else {
        report.error = options.lease.map { DeviceLeaseError.unknownLease($0).description }
            ?? "No active lease on \(options.deviceID ?? "?")."
        return finish(1)
    }
    report.lease = lease.id
    report.device = lease.deviceID

    let presented = options.lease ?? presentedLease(flag: nil)
    guard presented == lease.id || options.force else {
        report.error = DeviceLeaseError.leasedByOther(lease).description + " Use --force to release it anyway."
        return finish(3)
    }

    stopHolder(pid: lease.holderPID)
    report.holderStopped = lease.holderPID.map { kill($0, 0) != 0 } ?? true
    if options.shutdown, lease.bootedByLease || options.force {
        report.shutdown = await shutDownDevice(lease)
    }
    store.release(lease)
    report.ok = true
    return finish(0)
}

private func shutDownDevice(_ lease: DeviceLease) async -> Bool {
    let arguments = switch lease.platform {
    case .android: ["adb", "-s", lease.deviceID, "emu", "kill"]
    case .ios: ["xcrun", "simctl", "shutdown", lease.deviceID]
    }
    return await (try? SystemProcessRunner().run(arguments))?.exitCode == 0
}

// MARK: - env list

private struct EnvListEntry: Encodable {
    var lease: String
    var platform: String
    var device: String
    var name: String?
    var port: Int?
    var holderPID: Int32?
    var holderAlive: Bool
    var owner: String?
    var expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case lease, platform, device, name, port, owner
        case holderPID = "holder_pid"
        case holderAlive = "holder_alive"
        case expiresAt = "expires_at"
    }
}

func runEnvList(json: Bool, store: DeviceLeaseStore = DeviceLeaseStore()) -> CLIResult {
    let entries = store.all().map { lease in
        EnvListEntry(
            lease: lease.id,
            platform: lease.platform.rawValue,
            device: lease.deviceID,
            name: lease.deviceName,
            port: lease.port,
            holderPID: lease.holderPID,
            holderAlive: lease.holderPID.map { kill($0, 0) == 0 } ?? false,
            owner: lease.owner,
            expiresAt: lease.expiresAt
        )
    }
    if json {
        return CLIResult(output: renderJSON(["leases": entries]), exitCode: 0)
    }
    guard !entries.isEmpty else { return CLIResult(output: "No active leases.", exitCode: 0) }
    let format = ISO8601DateFormatter()
    let lines = entries.map { entry in
        "\(entry.lease)  \(entry.platform)  \(entry.device)  \(entry.name ?? "-")"
            + "  port=\(entry.port.map(String.init) ?? "-")"
            + "  holder=\(entry.holderAlive ? "alive" : "dead")  owner=\(entry.owner ?? "-")"
            + "  expires=\(format.string(from: entry.expiresAt))"
    }
    return CLIResult(output: lines.joined(separator: "\n"), exitCode: 0)
}

func handleEnvCommand(remaining: [String]) async -> CLIResult {
    if remaining.isEmpty || isHelpRequest(remaining) {
        return CLIResult(output: renderEnvHelp(), exitCode: remaining.isEmpty ? 64 : 0)
    }
    switch parseEnvCommand(args: remaining) {
    case let .failure(error):
        return CLIResult(output: error.description, exitCode: 64)
    case let .success(.up(options)):
        return await runEnvUp(options)
    case let .success(.down(options)):
        return await runEnvDown(options)
    case let .success(.list(json)):
        return runEnvList(json: json)
    }
}
