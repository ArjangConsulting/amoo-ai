import Foundation
import SwiftyShell
import Synchronization

/// Runner handles of companions left running past this process. A handle that is released tears its
/// process down, so they are parked here and never released.
private let handedOffRunners = Mutex<[any SpawnedProcess]>([])

/// Keeping a companion warm across amoo processes: taking over one an earlier server left running,
/// and leaving this server's own behind for the next session when it exits.
extension CompanionManager {
    /// Takes responsibility for a healthy companion this manager did not launch. A companion a live
    /// `amoo companion start` or `amoo env up` process registered stays that process's to end.
    func adopt(config: CompanionConfig, registry: CompanionRegistry = CompanionRegistry()) {
        guard !config.isPhysicalDevice, !config.isMac,
              !registry.entries().contains(where: { $0.platform == "ios" && $0.port == config.port })
        else { return }
        CompanionLingerStore().claim(platform: "ios", port: config.port)
        stateLock.withLock { adopted[config.deviceUDID] = config }
    }

    func adoptedConfig(deviceUDID: String) -> CompanionConfig? {
        stateLock.withLock { adopted[deviceUDID] }
    }

    /// Ends an adopted companion. Only a runner whose launching process is gone is stopped.
    func stopAdopted(deviceUDID: String) async {
        guard let config = stateLock.withLock({ adopted.removeValue(forKey: deviceUDID) }) else { return }
        _ = await reclaimOrphanedCompanion(config: config)
    }

    /// Called as the server exits. Healthy simulator companions are left running for `lingerSeconds`
    /// with a detached reaper, so the next server reuses them instead of paying the launch again.
    /// Everything else, and everything when the window is zero or no reaper could start, is stopped.
    func handOff(lingerSeconds: Double, hooks: CompanionLingerHooks = .live) async {
        let pending = stateLock.withLock { () -> [Task<Void, Never>] in
            defer { pendingIdleShutdowns.removeAll() }
            return Array(pendingIdleShutdowns.values)
        }
        pending.forEach { $0.cancel() }
        let (owned, taken) = stateLock.withLock { (Array(running.values), Array(adopted.values)) }
        for entry in owned {
            let config = entry.config
            guard !config.isPhysicalDevice, !config.isMac,
                  await isCompanionReady(host: config.host, port: config.port),
                  await leaveCompanionRunning(
                      platform: "ios",
                      deviceID: config.deviceUDID,
                      port: config.port,
                      seconds: lingerSeconds,
                      hooks: hooks
                  )
            else { continue }
            handedOffRunners.withLock { $0.append(entry.process) }
            stateLock.withLock { _ = running.removeValue(forKey: config.deviceUDID) }
        }
        for config in taken {
            let left = await leaveCompanionRunning(
                platform: "ios",
                deviceID: config.deviceUDID,
                port: config.port,
                seconds: lingerSeconds,
                hooks: hooks
            )
            if left {
                stateLock.withLock { _ = adopted.removeValue(forKey: config.deviceUDID) }
            } else {
                await stopAdopted(deviceUDID: config.deviceUDID)
            }
        }
        await shutdown()
    }
}
