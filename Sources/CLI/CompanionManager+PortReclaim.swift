import AmooCore
import Foundation
import ProcessRunner
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Where the listener on a port lives: its pid and, for a simulator companion, the device it serves.
struct CompanionListener: Equatable {
    var pid: Int32
    var simulatorUDID: String?
}

/// The process listening on `port`, with the simulator UDID read from its executable path.
func companionListener(port: Int, processRunner: any ProcessRunner) async -> CompanionListener? {
    guard let listing = try? await processRunner.run([
        "/usr/sbin/lsof", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"
    ]),
        listing.exitCode == 0,
        let pid = listenerPID(fromLsofOutput: listing.stdout)
    else { return nil }
    let command = try? await processRunner.run(["/bin/ps", "-p", String(pid), "-o", "comm="])
    let udid = command.flatMap { $0.exitCode == 0 ? simulatorUDID(inExecutablePath: $0.stdout) : nil }
    return CompanionListener(pid: pid, simulatorUDID: udid)
}

extension CompanionManager {
    /// Frees the port before a relaunch.
    ///
    /// `teardownAndWait` ends the `xcodebuild` the manager spawned, but the runner app inside the
    /// simulator is a separate process that can outlive it and keep the port bound. The relaunch
    /// then saw its own old runner and refused with "owned by another companion process" — which
    /// killed every restart of a detached holder. A listener inside this device's own simulator
    /// container is by construction ours to retire; anything else is left alone.
    ///
    /// - Parameter mayTakeOver: whether a same-device listener may be killed: the caller just
    ///   retired its own runner, or the user passed `--force`. Otherwise the port is left alone.
    /// - Returns: whether the port is free afterwards.
    func reclaimPort(config: CompanionConfig, mayTakeOver: Bool, graceSeconds: Double = 8) async -> Bool {
        if await !isTCPPortReachable(host: config.host, port: config.port, timeoutSeconds: 1.5) {
            return true
        }
        // The old runner is usually already exiting; give it a moment before signalling.
        if await waitForPortToFree(config: config, seconds: min(graceSeconds, 3)) {
            return true
        }
        guard let listener = await companionListener(port: config.port, processRunner: processRunner),
              let owner = listener.simulatorUDID,
              owner == config.deviceUDID.uppercased(),
              mayTakeOver
        else { return false }
        print("Retiring the leftover companion listener (pid \(listener.pid)) on port \(config.port).")
        kill(listener.pid, SIGTERM)
        if await waitForPortToFree(config: config, seconds: graceSeconds) {
            return true
        }
        kill(listener.pid, SIGKILL)
        return await waitForPortToFree(config: config, seconds: graceSeconds)
    }

    private func waitForPortToFree(config: CompanionConfig, seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if await !isTCPPortReachable(host: config.host, port: config.port, timeoutSeconds: 0.5) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await !isTCPPortReachable(host: config.host, port: config.port, timeoutSeconds: 0.5)
    }
}
