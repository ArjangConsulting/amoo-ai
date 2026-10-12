import Foundation
import SwiftyShell

/// Which companions a `CompanionManager` launched, per device. Sessions on different simulators run
/// side by side, so retiring or reusing one must never touch another.
extension CompanionManager {
    /// A companion this manager launched for one device.
    struct RunningCompanion {
        var process: any SpawnedProcess
        var config: CompanionConfig
    }

    /// Shuts down every companion this manager launched.
    func shutdown() async {
        let entries = stateLock.withLock { () -> [RunningCompanion] in
            defer { running.removeAll() }
            return Array(running.values)
        }
        for entry in entries {
            _ = await entry.process.teardownAndWait()
        }
    }

    /// Shuts down only the companion launched for `deviceUDID`, leaving other devices' sessions alone.
    func shutdown(deviceUDID: String) async {
        cancelIdleShutdown(deviceUDID: deviceUDID)
        guard let entry = stateLock.withLock({ running.removeValue(forKey: deviceUDID) }) else { return }
        _ = await entry.process.teardownAndWait()
    }

    func tracked(deviceUDID: String) -> RunningCompanion? {
        stateLock.withLock { running[deviceUDID] }
    }

    func trackedHolder(ofPort port: Int) -> RunningCompanion? {
        stateLock.withLock { running.values.first { $0.config.port == port } }
    }

    /// The only companion this manager launched, for the single-companion CLI commands that wait
    /// on "the" runner. With several tracked (an MCP server), the first stands in.
    func soleTracked() -> RunningCompanion? {
        stateLock.withLock { running.values.first }
    }

    func track(_ entry: RunningCompanion) {
        stateLock.withLock { running[entry.config.deviceUDID] = entry }
    }

    /// A companion this manager launched for another device already owns the port: reusing it would
    /// drive that device, and relaunching would collide with it.
    func refusePortHeldByAnotherDevice(config: CompanionConfig) throws {
        guard let holder = trackedHolder(ofPort: config.port), holder.config.deviceUDID != config.deviceUDID else {
            return
        }
        throw CompanionError.launchFailed(
            "Port \(config.port) is already used by the companion for \(holder.config.deviceUDID), "
                + "so it cannot also serve \(config.deviceUDID). \(companionPortAdvice)"
        )
    }
}

// MARK: - Idle shutdown

extension CompanionManager {
    /// How long a companion outlives the last session on its simulator before it is stopped.
    ///
    /// A companion is minutes of build and launch, so it stays warm for a following session; but one
    /// that stayed up for the life of the server also sat on the simulator after `end_session`,
    /// where a second XCTest runner (the app's own UI tests) shared it and swallowed taps.
    /// `AMOO_COMPANION_IDLE_SECONDS` overrides; 0 stops it as soon as the session ends.
    static func idleShutdownSeconds(environment: [String: String] = ProcessInfo.processInfo.environment) -> Double {
        guard let raw = environment["AMOO_COMPANION_IDLE_SECONDS"], let seconds = Double(raw), seconds >= 0 else {
            return 120
        }
        return seconds
    }

    /// Stops the companion for `deviceUDID` after `seconds` of no new session on it. A later
    /// `ensureRunning` for the same device cancels the pending stop.
    func scheduleIdleShutdown(deviceUDID: String, after seconds: Double) {
        guard tracked(deviceUDID: deviceUDID) != nil else { return }
        if seconds <= 0 {
            Task { await shutdown(deviceUDID: deviceUDID) }
            return
        }
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            await shutdown(deviceUDID: deviceUDID)
        }
        let previous = stateLock.withLock { () -> Task<Void, Never>? in
            defer { pendingIdleShutdowns[deviceUDID] = task }
            return pendingIdleShutdowns[deviceUDID]
        }
        previous?.cancel()
    }

    func cancelIdleShutdown(deviceUDID: String) {
        let pending = stateLock.withLock { pendingIdleShutdowns.removeValue(forKey: deviceUDID) }
        pending?.cancel()
    }
}
