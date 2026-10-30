import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A device whose session lock is currently held, and by whom.
struct DoctorDeviceLock: Encodable, Equatable {
    var device: String
    var pid: Int32
    var command: String
    var acquiredAt: Date
    /// False when the recorded holder has exited but something it spawned still holds the lock.
    var holderRunning: Bool
    var lockPath: String

    enum CodingKeys: String, CodingKey {
        case device, pid, command
        case acquiredAt = "acquired_at"
        case holderRunning = "holder_running"
        case lockPath = "lock_path"
    }
}

private let sessionLockSuffix = ".json.session-lock"

/// Held session locks with a recorded holder. A record alone is not proof (a crash leaves one
/// behind), so each is confirmed by trying the lock; a lock that can be taken is not reported.
func doctorDeviceLocks(store: DeviceRuntimeStore) -> [DoctorDeviceLock] {
    let files = (try? FileManager.default.contentsOfDirectory(
        at: store.accessDirectory, includingPropertiesForKeys: nil
    )) ?? []
    return files.compactMap { url -> DoctorDeviceLock? in
        let name = url.lastPathComponent
        guard name.hasSuffix(sessionLockSuffix), let holder = DeviceAccessHolder.read(path: url.path),
              isLockHeld(path: url.path)
        else { return nil }
        return DoctorDeviceLock(
            device: String(name.dropLast(sessionLockSuffix.count)),
            pid: holder.pid,
            command: holder.command,
            acquiredAt: holder.acquiredAt,
            holderRunning: holder.isAlive,
            lockPath: url.path
        )
    }
    .sorted { $0.device < $1.device }
}

private func isLockHeld(path: String) -> Bool {
    let file = open(path, O_RDWR | O_CLOEXEC)
    guard file >= 0 else { return false }
    defer { close(file) }
    guard flock(file, LOCK_EX | LOCK_NB) == 0 else { return true }
    _ = flock(file, LOCK_UN)
    return false
}

func doctorDeviceLockIssues(_ report: DoctorReport) -> [String] {
    report.deviceLocks.compactMap { lock in
        if !lock.holderRunning {
            return "Device \(lock.device) is locked by a process that outlived pid \(lock.pid) "
                + "(\(lock.command)); the next amoo start on it discards the lock, or remove \(lock.lockPath)."
        }
        if report.mcpServers.contains(where: { $0.pid == lock.pid && $0.stale }) {
            return "Device \(lock.device) is held by stale MCP server pid \(lock.pid); "
                + "`amoo doctor --mcp-pid \(lock.pid) --kill-stale` releases it."
        }
        return nil
    }
}

func doctorDeviceLockNotes(_ report: DoctorReport) -> [String] {
    report.deviceLocks.filter { lock in
        lock.holderRunning && !report.mcpServers.contains { $0.pid == lock.pid && $0.stale }
    }
    .map { lock in
        "Device \(lock.device) is in use by pid \(lock.pid) (\(lock.command)) since "
            + "\(ISO8601DateFormatter().string(from: lock.acquiredAt)); end that session to free it."
    }
}

/// A companion that accepts connections but does not serve gRPC cannot be driven. Reported as a
/// note, not an issue: the listener may belong to another client, and `env down` refuses while a
/// session is active, so running it is safe for the lease's owner.
func doctorUnresponsiveCompanionNotes(_ report: DoctorReport) -> [String] {
    report.companions.filter { $0.state == .unresponsive }.map { companion in
        let device = companion.device.map { " for \($0)" } ?? ""
        let recovery = companion.device.map { "`amoo env down --device \($0)` releases your own lease on it" }
            ?? "if it is yours, end the session that started it"
        let owner = companion.pid.map { "pid \($0) " } ?? ""
        return "Companion \(owner)on port \(companion.port)\(device) is unresponsive; \(recovery). "
            + "Leave it alone if another client owns it, and use a different device."
    }
}
