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

    func waitForPortToFree(config: CompanionConfig, seconds: Double) async -> Bool {
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

// MARK: - Orphaned runners

/// `xcodebuild` companion runners for `udid` whose parent is gone (reparented to launchd).
///
/// An `amoo mcp serve` that was killed or crashed leaves its `xcodebuild test-without-building`
/// child running, and with it the runner app holding the port. A live owner is the runner's parent,
/// so pid 1 as the parent is what tells an orphan from a companion another amoo is using.
func parseOrphanedCompanionRunners(psOutput: String, udid: String) -> [Int32] {
    let wanted = udid.uppercased()
    return psOutput.split(whereSeparator: \.isNewline).compactMap { line -> Int32? in
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]), parent == 1 else {
            return nil
        }
        let arguments = String(fields[2])
        guard arguments.contains("xcodebuild"), arguments.contains("AmooCompanion"),
              arguments.uppercased().contains(wanted)
        else { return nil }
        return pid
    }
}

extension CompanionManager {
    /// Retires a companion left behind by an amoo process that died, so a new session on the same
    /// simulator starts instead of failing with "owned by another companion process".
    ///
    /// Only an orphan is touched: a runner whose parent is a live process belongs to someone using it.
    /// - Returns: whether the port is free afterwards.
    func reclaimOrphanedCompanion(config: CompanionConfig, graceSeconds: Double = 8) async -> Bool {
        guard !config.isPhysicalDevice,
              let listing = try? await processRunner.run(["/bin/ps", "-axo", "pid=,ppid=,args="]),
              listing.exitCode == 0
        else { return false }
        let orphans = parseOrphanedCompanionRunners(psOutput: listing.stdout, udid: config.deviceUDID)
        guard !orphans.isEmpty else { return false }
        let pids = orphans.map(String.init).joined(separator: ", ")
        print("Retiring a companion left behind by a dead amoo process (pid \(pids)).")
        orphans.forEach { kill($0, SIGTERM) }
        if let listener = await companionListener(port: config.port, processRunner: processRunner),
           listener.simulatorUDID == config.deviceUDID.uppercased() {
            kill(listener.pid, SIGTERM)
        }
        if await waitForPortToFree(config: config, seconds: graceSeconds) {
            return true
        }
        orphans.forEach { kill($0, SIGKILL) }
        if let listener = await companionListener(port: config.port, processRunner: processRunner),
           listener.simulatorUDID == config.deviceUDID.uppercased() {
            kill(listener.pid, SIGKILL)
        }
        return await waitForPortToFree(config: config, seconds: graceSeconds)
    }
}

extension CompanionManager {
    /// Stops the companion for `config`'s device whoever launched it, and reports what was done.
    ///
    /// For recovery: a wedged runner, or one a dead amoo process left holding the port. Anything
    /// serving this device's simulator on the port is retired; a listener elsewhere is left alone.
    func resetCompanion(config: CompanionConfig) async -> String {
        let hadOwn = tracked(deviceUDID: config.deviceUDID) != nil
        await shutdown(deviceUDID: config.deviceUDID)
        var freed = await reclaimPort(config: config, mayTakeOver: true)
        if !freed {
            freed = await reclaimOrphanedCompanion(config: config)
        }
        let listening = await isTCPPortReachable(host: config.host, port: config.port, timeoutSeconds: 1.0)
        if freed, !listening {
            return hadOwn ? "companion stopped; port \(config.port) is free" : "port \(config.port) is free"
        }
        return "port \(config.port) is still held by a process that is not this device's companion;"
            + " stop it, or start the session with another `port`"
    }
}

extension CompanionManager {
    func stopCompanion(config: CompanionConfig) async {
        await shutdown(deviceUDID: config.deviceUDID)
        _ = await reclaimOrphanedCompanion(config: config)
    }
}

extension CompanionManager {
    /// Makes the port free for a launch, or throws saying who holds it.
    ///
    /// Retires this device's own runner if it stopped answering, then anything provably this device's
    /// that outlived it (the runner app can survive its `xcodebuild`), then a companion an amoo
    /// process that died left behind. A companion started by a separate, live `amoo companion start`
    /// still owns the port and is never touched without `--force`.
    func freePortForLaunch(config: CompanionConfig, ownedRunner: Bool, force: Bool) async throws {
        if ownedRunner {
            await shutdown(deviceUDID: config.deviceUDID)
        }
        var portFree = await reclaimPort(config: config, mayTakeOver: ownedRunner || force)
        if !portFree {
            portFree = await reclaimOrphanedCompanion(config: config)
        }
        guard !portFree, await isTCPPortReachable(host: config.host, port: config.port, timeoutSeconds: 1.5) else {
            return
        }
        let retryHint = force
            ? "Stop that process (Ctrl-C in its terminal) and retry."
            : "Stop its 'amoo companion start' process, then retry with --force."
        throw CompanionError.launchFailed(
            "Port \(config.port) is owned by another companion process. \(retryHint) "
                + "Or use a different port: \(companionPortAdvice)"
        )
    }
}
