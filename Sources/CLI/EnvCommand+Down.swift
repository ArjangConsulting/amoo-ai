import AmooCore
import AmooLogging
import Foundation
import MobileDevices
import ProcessRunner
import SwiftyShell
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct EnvDownReport: Codable {
    var ok: Bool
    var runtimeID: String?
    var device: String?
    var companionStopped: Bool
    var shutdown: Bool
    var error: String?
    /// Processes found running with no runtime (`env down --device`), all stopped when `ok`.
    var orphansStopped: [Int32]?
    var state: DeviceRuntimeState?

    enum CodingKeys: String, CodingKey {
        case ok, device, shutdown, error, state
        case runtimeID = "runtime_id"
        case orphansStopped = "orphans_stopped"
        case companionStopped = "companion_stopped"
    }
}

struct EnvDownDependencies {
    var stop: (DeviceRuntime) -> Bool = stopRuntimeCompanion
    var stopAndroid: (String) async -> Bool = forceStopAndroidCompanion
    var shutdown: (DeviceRuntime) async -> Bool = shutDownDevice
}

private let envDownLogger = AmooLogger.forType(EnvDownDependencies.self)

func runEnvDown(
    _ options: EnvDownOptions,
    store: DeviceRuntimeStore = DeviceRuntimeStore(),
    dependencies: EnvDownDependencies = EnvDownDependencies()
) async -> CLIResult {
    var report = EnvDownReport(ok: false, companionStopped: false, shutdown: false)
    logEnvDownStart(options)
    let finish: (Int32) -> CLIResult = { code in
        logEnvDownFinish(report, exitCode: code)
        let human = envDownSummary(report)
        return CLIResult(output: options.json ? renderJSON(report) : human, exitCode: code)
    }

    let runtime: DeviceRuntime? = if let id = options.runtimeID {
        store.runtime(id: id, includingExpired: true)
    } else {
        store.allIncludingExpired().first { $0.deviceID == options.deviceID }
    }
    guard let runtime else {
        let orphan = await stopOrphanedRuntime(options, store: store, dependencies: dependencies)
        report = orphan.report
        return finish(orphan.exitCode)
    }
    report.runtimeID = runtime.id
    report.device = runtime.deviceID

    if let deviceID = options.deviceID, deviceID != runtime.deviceID {
        report.error = "The runtime belongs to a different device."
        return finish(3)
    }
    if let refusal = envDownRefusal(options, runtime: runtime) {
        report.error = refusal
        return finish(3)
    }
    let access: DeviceAccessLock
    do {
        access = try DeviceAccessLock(deviceID: runtime.deviceID, store: store)
    } catch {
        report.error = "Device is being controlled by another session: \(runtime.deviceID)."
        return finish(3)
    }
    defer { access.release() }

    if let failure = await stopCompanions(runtime, options: options, dependencies: dependencies, report: &report) {
        report.error = failure
        return finish(1)
    }
    if options.shutdown, runtime.bootedByRuntime || options.force {
        report.shutdown = await dependencies.shutdown(runtime)
        if !report.shutdown {
            report.error = "Companion stopped, but device shutdown failed."
        }
    }
    report.state = .stopped
    let removed = store.stop(runtime)
    report.ok = removed && report.error == nil
    if !removed {
        report.error = "Could not remove the runtime record."
    }
    return finish(report.ok ? 0 : 1)
}

private func logEnvDownStart(_ options: EnvDownOptions) {
    envDownLogger.info(
        "Stopping runtime",
        context: "action=env-down runtime=\(options.runtimeID ?? "-") device=\(options.deviceID ?? "-")"
            + " force=\(options.force)"
    )
}

private func logEnvDownFinish(_ report: EnvDownReport, exitCode: Int32) {
    let context = "action=env-down exit=\(exitCode) runtime=\(report.runtimeID ?? "-")"
    if let error = report.error {
        envDownLogger.error("Runtime stop failed", context: context + " reason=\(error)")
    } else {
        envDownLogger.info("Runtime stopped", context: context + " shutdown=\(report.shutdown)")
    }
}

/// Why the caller may not stop `runtime`, nil when it may. Stopping someone else's live runtime
/// needs `--force`; an expired runtime reads as free, so anyone may clean it up.
private func envDownRefusal(_ options: EnvDownOptions, runtime: DeviceRuntime) -> String? {
    let presented = (options.runtimeID ?? presentedRuntime(flag: nil)).map(DeviceRuntimeStore.normalizedID)
    guard presented == runtime.id || options.force || runtime.isExpired() else {
        return DeviceAccessError.controlledByOther(runtime).description + " Use --force to stop it anyway."
    }
    return nil
}

/// Stops the host companion process and, on Android, the on-device runner. Returns the failure to
/// report, nil on success. `--force` carries on past a failed stop so the record can still be cleared.
private func stopCompanions(
    _ runtime: DeviceRuntime,
    options: EnvDownOptions,
    dependencies: EnvDownDependencies,
    report: inout EnvDownReport
) async -> String? {
    let retry = " Retry with --force to remove the record anyway."
    report.companionStopped = dependencies.stop(runtime)
    guard report.companionStopped || options.force else {
        return "Could not stop the companion process." + retry
    }
    if runtime.platform == .android, await !dependencies.stopAndroid(runtime.deviceID) {
        report.companionStopped = false
        if !options.force {
            return "Could not stop the on-device companion; runtime record retained for cleanup." + retry
        }
    }
    return nil
}

private func shutDownDevice(_ runtime: DeviceRuntime) async -> Bool {
    let context = ShellContext(executor: ProcessRunnerCommandExecutor(processRunner: SystemProcessRunner()))
    do {
        switch runtime.platform {
        case .android: try await ADBRunner(context: context).killEmulator(serial: runtime.deviceID)
        case .ios: try await SimulatorManager(shell: context).shutdown(runtime.deviceID)
        }
        return true
    } catch { return false }
}

// MARK: - env list

private struct EnvListEntry: Encodable {
    var runtimeID: String
    var platform: String
    var device: String
    var name: String?
    var port: Int?
    var companionPID: Int32?
    var state: DeviceRuntimeState
    var owner: String?
    var expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case platform, device, name, port, owner
        case runtimeID = "runtime_id"
        case companionPID = "companion_pid"
        case state
        case expiresAt = "expires_at"
    }
}

func runEnvList(
    json: Bool,
    store: DeviceRuntimeStore = DeviceRuntimeStore(),
    health: DeviceRuntimeHealth = DeviceRuntimeHealth()
) async -> CLIResult {
    let observations = await health.observe(store.allIncludingExpired())
    let entries = observations.map { runtime in
        EnvListEntry(
            runtimeID: runtime.id,
            platform: runtime.platform.rawValue,
            device: runtime.deviceID,
            name: runtime.deviceName,
            port: runtime.port,
            companionPID: runtime.companionPID,
            state: runtime.state,
            owner: runtime.owner,
            expiresAt: runtime.expiresAt
        )
    }
    if json {
        return CLIResult(output: renderJSON(["runtimes": entries]), exitCode: 0)
    }
    guard !entries.isEmpty else { return CLIResult(output: "No active runtimes.", exitCode: 0) }
    let format = ISO8601DateFormatter()
    let lines = entries.map { entry in
        "\(entry.runtimeID)  \(entry.platform)  \(entry.device)  \(entry.name ?? "-")"
            + "  port=\(entry.port.map(String.init) ?? "-")"
            + "  state=\(entry.state.rawValue)  owner=\(entry.owner ?? "-")"
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
        return await runEnvList(json: json)
    }
}

private func envDownSummary(_ report: EnvDownReport) -> String {
    guard report.ok else { return "env down failed: \(report.error ?? "unknown error")" }
    if report.runtimeID == nil {
        let processes = report.orphansStopped?.map { String($0) }.joined(separator: ", ") ?? "none"
        return "No runtime on \(report.device ?? "?"); stopped orphaned companion process(s): \(processes)."
    }
    return "Stopped amoo on \(report.device ?? "?")"
        + (report.shutdown ? "; device shut down." : ".")
}
