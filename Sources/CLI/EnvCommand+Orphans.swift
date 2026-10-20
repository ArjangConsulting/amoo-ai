import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func stopOrphanedRuntime(
    _ options: EnvDownOptions,
    store: DeviceRuntimeStore,
    dependencies: EnvDownDependencies
) async -> (report: EnvDownReport, exitCode: Int32) {
    var report = EnvDownReport(ok: false, companionStopped: false, shutdown: false)
    guard options.runtimeID == nil, let deviceID = options.deviceID else {
        report.error = options.runtimeID.map { DeviceAccessError.unknownRuntime($0).description }
        return (report, 1)
    }
    report.device = deviceID
    do {
        let access = try DeviceAccessLock(deviceID: deviceID, store: store)
        defer { access.release() }
        let orphans = await orphanedCompanionProcesses(deviceID: deviceID)
        for pid in orphans {
            if let command = processCommandLine(pid: pid), isCompanionProcessCommand(command, deviceID: deviceID) {
                stopProcess(pid: pid)
            }
        }
        let onDeviceStopped = if deviceID.hasPrefix("emulator-") {
            await dependencies.stopAndroid(deviceID)
        } else {
            true
        }
        report.orphansStopped = orphans
        report.companionStopped = onDeviceStopped && orphans.allSatisfy { kill($0, 0) != 0 }
        report.ok = report.companionStopped
        report.state = report.ok ? .stopped : .unresponsive
        report.error = report.ok ? nil : "Could not stop orphaned companion processes."
    } catch {
        report.error = "Device is being controlled by another session: \(deviceID)."
        return (report, 3)
    }
    return (report, report.ok ? 0 : 1)
}
