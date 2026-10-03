import AmooCore
import Foundation
import ProcessRunner
import SwiftyShell

/// Per-device lifecycle: sessions on different emulators run concurrently, so state is keyed by serial.
extension AndroidCompanionManager {
    /// Shuts down every companion this manager launched.
    func shutdown() async {
        let serials = stateLock.withLock { Array(running.keys) }
        for key in serials {
            await shutdown(serial: key.isEmpty ? nil : key)
        }
    }

    /// Shuts down only the companion launched for `serial`, leaving other devices' sessions alone.
    func shutdown(serial: String?) async {
        guard let entry = stateLock.withLock({ running.removeValue(forKey: Self.stateKey(serial)) }) else { return }
        if let process = entry.process {
            _ = await process.teardownAndWait()
        }
        await clearStaleCompanion(config: entry.config)
    }

    static func stateKey(_ serial: String?) -> String {
        serial ?? ""
    }

    func tracked(serial: String?) -> RunningCompanion? {
        stateLock.withLock { running[Self.stateKey(serial)] }
    }

    func setTracked(_ entry: RunningCompanion) {
        stateLock.withLock { running[Self.stateKey(entry.config.serial)] = entry }
    }

    func firstTrackedProcess() -> (any SpawnedProcess)? {
        stateLock.withLock { running.values.lazy.compactMap(\.process).first }
    }

    /// True when a companion this manager launched for a different device already owns the port.
    func isPortHeldByOtherDevice(config: AndroidCompanionConfig) -> Bool {
        stateLock.withLock {
            running.values.contains { $0.config.port == config.port && $0.config.serial != config.serial }
        }
    }

    /// Emulators map to a fixed port by console number (`emulator-5554` → 22088, `emulator-5556` →
    /// 22089, …), so every process agrees on it with no coordination and a companion left running
    /// by an earlier server is found again. Any other serial gets the first free port above that
    /// range, remembered for the lifetime of this manager.
    func companionPort(forSerial serial: String) async -> Int {
        if let fixed = AndroidCompanionConfig.emulatorPort(forSerial: serial) {
            return fixed
        }
        if let existing = stateLock.withLock({ fallbackPorts[serial] }) {
            return existing
        }
        if let forwarded = try? await forwardedAndroidCompanionPort(
            forSerial: serial,
            context: shellContext
        ) {
            stateLock.withLock { fallbackPorts[serial] = forwarded }
            return forwarded
        }
        for candidate in AndroidCompanionConfig.fallbackPortBase ... AndroidCompanionConfig.maxPort {
            guard !stateLock.withLock({ fallbackPorts.values.contains(candidate) }),
                  await !isTCPPortReachable(host: "127.0.0.1", port: candidate, timeoutSeconds: 0.5)
            else { continue }
            // Claim under the lock: a concurrent call may have taken this port or this serial meanwhile.
            let claimed: Int? = stateLock.withLock {
                if let existing = fallbackPorts[serial] {
                    return existing
                }
                guard !fallbackPorts.values.contains(candidate) else { return nil }
                fallbackPorts[serial] = candidate
                return candidate
            }
            if let claimed {
                return claimed
            }
        }
        return AndroidCompanionConfig.defaultPort
    }
}
