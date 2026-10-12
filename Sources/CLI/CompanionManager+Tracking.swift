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
