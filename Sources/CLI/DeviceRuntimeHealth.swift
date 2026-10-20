import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Read-only probes; a saved record alone never establishes that a companion is running.
struct DeviceRuntimeHealth {
    var processMatches: (Int32, String) -> Bool = { pid, device in
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM,
              let command = processCommandLine(pid: pid)
        else { return false }
        return isCompanionProcessCommand(command, deviceID: device)
    }

    var isReady: (DeviceRuntime) async -> Bool = runtimeEndpointReady

    func state(of runtime: DeviceRuntime, now: Date = Date()) async -> DeviceRuntimeState {
        if runtime.state == .stopped {
            return .stopped
        }
        if let pid = runtime.companionPID {
            guard processMatches(pid, runtime.deviceID) else { return .stale }
        } else {
            return !runtime.isExpired(at: now) && runtime.state == .starting
                && now.timeIntervalSince(runtime.createdAt) < 600 ? .starting : .stale
        }
        if runtime.port != nil, await isReady(runtime) {
            return .running
        }
        if runtime.isExpired(at: now) {
            return .stale
        }
        return runtime.state == .starting && now.timeIntervalSince(runtime.createdAt) < 600 ? .starting : .unresponsive
    }

    func observe(_ runtimes: [DeviceRuntime]) async -> [DeviceRuntime] {
        var observations: [DeviceRuntime] = []
        for var runtime in runtimes {
            runtime.state = await state(of: runtime)
            observations.append(runtime)
        }
        return observations
    }
}
