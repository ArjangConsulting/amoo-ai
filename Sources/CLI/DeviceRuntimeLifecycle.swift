import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Stops only a verified companion process. A reused PID is unrelated to the stale runtime.
func stopRuntimeCompanion(_ runtime: DeviceRuntime) -> Bool {
    guard let pid = runtime.companionPID, pid > 0, kill(pid, 0) == 0, let command = processCommandLine(pid: pid),
          isCompanionProcessCommand(command, deviceID: runtime.deviceID)
    else { return true }
    stopProcess(pid: pid)
    return kill(pid, 0) != 0
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
    guard let runtime = store.runtime(id: id) else {
        report.error = DeviceAccessError.unknownRuntime(id).description
        return report
    }
    report.runtimeID = runtime.id
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
    guard state == .running else {
        report.error = "Runtime is \(state.rawValue). Stop it with `amoo env down --runtime-id \(runtime.id)` first."
        return report
    }
    do {
        let access = try DeviceAccessLock(deviceID: runtime.deviceID, store: store)
        defer { access.release() }
        report.prepareApp(options)
        _ = try store.refresh(runtime)
        access.release()
        try await dependencies.prepare(options, runtime, &report.app)
        _ = try store.refresh(runtime)
        report.ok = true
        report.state = .running
    } catch {
        report.error = "\(error)"
    }
    return report
}
