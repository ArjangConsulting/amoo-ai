import AmooLogging
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let lifecycleLogger = AmooLogger.forType(DeviceRuntimeStore.self)

/// Stops only a verified companion process. A reused PID is unrelated to the stale runtime.
func stopRuntimeCompanion(_ runtime: DeviceRuntime) -> Bool {
    guard let pid = runtime.companionPID, pid > 0, kill(pid, 0) == 0, let command = processCommandLine(pid: pid),
          isCompanionProcessCommand(command, deviceID: runtime.deviceID)
    else { return true }
    lifecycleLogger.info(
        "Stopping companion process",
        context: "action=stop-companion runtime=\(runtime.id) pid=\(pid)"
    )
    stopProcess(pid: pid)
    let stopped = kill(pid, 0) != 0
    lifecycleLogger.info(
        "Companion process stop finished",
        context: "action=stop-companion runtime=\(runtime.id) pid=\(pid) stopped=\(stopped)"
    )
    return stopped
}

/// Reuses an owned, reachable runtime without starting a second companion.
func reuseDeviceRuntime(
    _ options: EnvUpOptions,
    store: DeviceRuntimeStore,
    dependencies: EnvUpDependencies
) async -> EnvUpReport? {
    // Only the explicit flag reuses a runtime. An exported AMOO_RUNTIME_ID must not turn a later
    // `env up` for another device or platform into a reuse attempt.
    guard let id = options.runtimeID.flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
    var report = EnvUpReport(ok: false, platform: options.platform.rawValue)
    guard var runtime = store.runtime(id: id, includingExpired: true) else {
        report.error = DeviceAccessError.unknownRuntime(id).description
        return report
    }
    report.runtimeID = runtime.id
    lifecycleLogger.info("Reusing runtime", context: "action=reuse runtime=\(runtime.id) device=\(runtime.deviceID)")
    guard runtime.amooPlatform == options.platform,
          options.deviceID == nil || options.deviceID == runtime.deviceID,
          options.port == nil || options.port == runtime.port,
          options.avd == nil || options.avd == runtime.deviceName
    else {
        report.error = "The runtime does not match the requested platform, device, AVD or port."
        return report
    }
    report.device = EnvDeviceReport(
        id: runtime.deviceID,
        name: runtime.deviceName,
        bootedByEnv: runtime.bootedByRuntime
    )
    report.port = runtime.port
    report.companionPID = runtime.companionPID
    report.log = store.logURL(runtimeID: runtime.id).path
    let state = await dependencies.health.state(of: runtime)
    guard [.running, .stale, .unresponsive].contains(state) else {
        report.error = "Runtime is \(state.rawValue). Wait for startup or explicitly stop it before retrying."
        return report
    }
    do {
        let access = try DeviceAccessLock(deviceID: runtime.deviceID, store: store)
        defer { access.release() }
        let recoveryStarted = ContinuousClock.now
        if state != .running {
            runtime = try await recoverOwnedRuntime(runtime, options: options, store: store, dependencies: dependencies)
            report.recovered = true
            report.recoveryMilliseconds = runtimeRecoveryMilliseconds(since: recoveryStarted)
            report.port = runtime.port
            report.companionPID = runtime.companionPID
        }
        report.prepareApp(options)
        if let appID = options.appID {
            runtime.appID = appID
        }
        _ = try store.refresh(runtime)
        access.release()
        try await dependencies.prepare(options, runtime, &report.app)
        try refreshOwnedRuntime(runtime.id, store: store)
        report.ok = true
        report.state = .running
    } catch {
        lifecycleLogger.error(
            "Runtime reuse failed",
            error: error,
            context: "action=reuse runtime=\(runtime.id) device=\(runtime.deviceID)"
        )
        report.error = "\(error)"
    }
    return report
}

private func refreshOwnedRuntime(_ id: String, store: DeviceRuntimeStore) throws {
    guard let current = store.runtime(id: id, includingExpired: true) else {
        throw DeviceAccessError.unknownRuntime(id)
    }
    _ = try store.refresh(current)
}

private func recoverOwnedRuntime(
    _ original: DeviceRuntime, options: EnvUpOptions, store: DeviceRuntimeStore, dependencies: EnvUpDependencies
) async throws -> DeviceRuntime {
    guard store.runtime(id: original.id, includingExpired: true)?.deviceID == original.deviceID else {
        throw DeviceAccessError.unknownRuntime(original.id)
    }
    guard await dependencies.stop(original) else {
        throw EnvError.companionFailed("Could not stop this runtime's companion; ownership retained for retry.")
    }
    var runtime = original
    runtime.state = .starting
    runtime.companionPID = nil
    runtime = try store.refresh(runtime)
    return try await dependencies.start(options, runtime, store)
}

private func runtimeRecoveryMilliseconds(since started: ContinuousClock.Instant) -> Int {
    let duration = started.duration(to: .now).components
    return Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
}
