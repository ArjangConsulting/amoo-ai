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

    /// - Throws: ``MobileKitError/deviceClaimed(device:holder:)`` when another session holds it.
    init(deviceID: String, store: DeviceRuntimeStore, runtimeRecord: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: store.accessDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let path = store.accessFileURL(deviceID: deviceID)
            .appendingPathExtension(runtimeRecord ? "runtime-lock" : "session-lock").path
        let file = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(file, runtimeRecord ? LOCK_EX : LOCK_EX | LOCK_NB) == 0 else {
            close(file)
            throw MobileKitError.deviceClaimed(device: deviceID, holder: "another active session")
        }
        self.deviceID = deviceID
        descriptor = Mutex(file)
    }

    func release() {
        descriptor.withLock { file in
            if file >= 0 {
                _ = flock(file, LOCK_UN)
                close(file)
                file = -1
            }
        }
    }

    deinit { release() }
}
