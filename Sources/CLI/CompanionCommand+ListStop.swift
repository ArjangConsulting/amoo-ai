import AmooCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - `amoo companion list` / `amoo companion stop`

/// How list and stop reach processes and ports, so tests drive every outcome without a device.
struct CompanionListStopHooks: Sendable {
    var registry: CompanionRegistry
    var isReady: @Sendable (_ port: Int) async -> Bool
    var isAlive: @Sendable (_ pid: Int32) -> Bool
    var terminate: @Sendable (_ pid: Int32) -> Void
    var forceKill: @Sendable (_ pid: Int32) -> Void
    /// How long a holder gets to exit after SIGTERM before SIGKILL.
    var graceSeconds: Double

    static let live = Self(
        registry: CompanionRegistry(),
        isReady: { await isCompanionReady(host: "127.0.0.1", port: $0) },
        isAlive: { kill($0, 0) == 0 || errno == EPERM },
        terminate: { _ = kill($0, SIGTERM) },
        forceKill: { _ = kill($0, SIGKILL) },
        graceSeconds: 20
    )
}

/// Prints one row per live holder: pid, platform, port, device, app and whether it answers.
func runCompanionList(hooks: CompanionListStopHooks = .live) async -> CLIResult {
    let entries = hooks.registry.entries(isAlive: hooks.isAlive)
    guard !entries.isEmpty else {
        return CLIResult(output: "No companions running (started with `amoo companion start`).", exitCode: 0)
    }
    var lines = ["PID\tPLATFORM\tPORT\tSTATE\tDEVICE\tAPP"]
    for entry in entries {
        let state = await hooks.isReady(entry.port) ? "ready" : "starting"
        lines.append(
            "\(entry.pid)\t\(entry.platform)\t\(entry.port)\t\(state)\t\(entry.deviceID)\t\(entry.appID ?? "-")"
        )
    }
    return CLIResult(output: lines.joined(separator: "\n"), exitCode: 0)
}

/// Stops the holders matching `--port` / `--device` (or every one with `--all`), leaving all other
/// companions — including other sessions' — running.
func runCompanionStop(
    options: CompanionCommandOptions,
    hooks: CompanionListStopHooks = .live
) async -> CLIResult {
    let deviceFilter = options.deviceID == "booted" ? nil : options.deviceID
    guard options.port != nil || deviceFilter != nil || options.all else {
        return CLIResult(
            output: "companion stop needs --port <port>, --device <id>, or --all. "
                + "Run `amoo companion list` to see what is running.",
            exitCode: 64
        )
    }
    let matches = hooks.registry.entries(isAlive: hooks.isAlive).filter { entry in
        if options.all {
            return true
        }
        if let port = options.port, entry.port != port {
            return false
        }
        if let device = deviceFilter, entry.deviceID.caseInsensitiveCompare(device) != .orderedSame {
            return false
        }
        return true
    }
    guard !matches.isEmpty else {
        return CLIResult(output: "No running companion matches. See `amoo companion list`.", exitCode: 1)
    }
    var lines: [String] = []
    var failed = false
    for entry in matches {
        if await stopHolder(entry, hooks: hooks) {
            lines.append("Stopped companion on port \(entry.port) (pid \(entry.pid)).")
        } else {
            failed = true
            lines.append("Could not stop companion on port \(entry.port) (pid \(entry.pid)).")
        }
    }
    return CLIResult(output: lines.joined(separator: "\n"), exitCode: failed ? 1 : 0)
}

/// SIGTERM lets the holder tear its runner down cleanly; SIGKILL only after the grace period.
private func stopHolder(_ entry: CompanionRegistration, hooks: CompanionListStopHooks) async -> Bool {
    hooks.terminate(entry.pid)
    if await waitForExit(entry.pid, seconds: hooks.graceSeconds, hooks: hooks) {
        return true
    }
    hooks.forceKill(entry.pid)
    let gone = await waitForExit(entry.pid, seconds: 3, hooks: hooks)
    if gone {
        hooks.registry.unregister(platform: entry.platform, port: entry.port, pid: entry.pid)
    }
    return gone
}

private func waitForExit(_ pid: Int32, seconds: Double, hooks: CompanionListStopHooks) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while ContinuousClock.now < deadline {
        if !hooks.isAlive(pid) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return !hooks.isAlive(pid)
}

/// Records this process as the holder of a companion until the returned closure runs.
func registerCompanionHolder(
    platform: CompanionPlatform,
    deviceID: String,
    port: Int,
    appID: String?,
    registry: CompanionRegistry = CompanionRegistry()
) -> @Sendable () -> Void {
    let pid = getpid()
    registry.register(CompanionRegistration(
        pid: pid, platform: platform.rawValue, deviceID: deviceID, port: port, appID: appID, startedAt: Date()
    ))
    return { registry.unregister(platform: platform.rawValue, port: port, pid: pid) }
}
