import AmooLogging
import Foundation
import MobileCore
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Kernel-backed exclusive ownership of a device for the life of a session, shared by every
/// process. The kernel releases it if the holder crashes; the lock file is never unlinked while
/// another process may be opening it.
///
/// `flock` locks belong to an open file description: a second lock on the same device from the
/// same process fails like one from another process.
final class DeviceAccessLock: Sendable {
    private let descriptor: Mutex<Int32>
    let deviceID: String

    /// A session lock records its holder in the lock file so a refused caller can name it. If the
    /// recorded holder is gone but the lock is still held, a descendant leaked the descriptor; the
    /// lock file is replaced so the device is not stuck behind a process that cannot end a session.
    ///
    /// - Throws: ``MobileKitError/deviceClaimed(device:holder:)`` when another session holds it.
    init(deviceID: String, store: DeviceRuntimeStore, runtimeRecord: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: store.accessDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let path = store.accessFileURL(deviceID: deviceID)
            .appendingPathExtension(runtimeRecord ? "runtime-lock" : "session-lock").path
        var file = try Self.lock(path: path, wait: runtimeRecord)
        if file == nil,
           let holder = DeviceAccessHolder.read(path: path), !holder.isAlive,
           Self.discardOrphanedLock(path: path, holder: holder, deviceID: deviceID) {
            file = try Self.lock(path: path, wait: false)
        }
        guard let file else {
            let holder = DeviceAccessHolder.read(path: path)?.refusal(lockPath: path)
                ?? "another active session (holder not recorded; `lsof \(path)` names it)"
            throw MobileKitError.deviceClaimed(device: deviceID, holder: holder)
        }
        if !runtimeRecord {
            DeviceAccessHolder.current().write(to: file)
        }
        self.deviceID = deviceID
        descriptor = Mutex(file)
    }

    /// Opens and locks `path`; `nil` when another open file description holds it.
    private static func lock(path: String, wait: Bool) throws -> Int32? {
        let file = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(file, wait ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else {
            close(file)
            return nil
        }
        return file
    }

    /// Unlinks a lock file whose recorded holder is dead. Serialized by a guard lock and re-checked
    /// under it, so two recoverers cannot both unlink and each lock a fresh file.
    private static func discardOrphanedLock(path: String, holder: DeviceAccessHolder, deviceID: String) -> Bool {
        let guardFile = open(path + ".recover", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard guardFile >= 0 else { return false }
        defer { close(guardFile) }
        guard flock(guardFile, LOCK_EX | LOCK_NB) == 0, DeviceAccessHolder.read(path: path) == holder else {
            return false
        }
        logger.info(
            "Discarding device lock held by a dead process",
            context: "action=recover device=\(deviceID) holderPID=\(holder.pid)"
        )
        return unlink(path) == 0
    }

    private static let logger = AmooLogger.forType(DeviceAccessLock.self)

    func release() {
        descriptor.withLock { file in
            if file >= 0 {
                DeviceAccessHolder.clear(descriptor: file)
                _ = flock(file, LOCK_UN)
                close(file)
                file = -1
            }
        }
    }

    deinit { release() }
}
