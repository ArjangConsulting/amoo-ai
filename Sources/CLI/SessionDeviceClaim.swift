import AmooCore
import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Kernel-backed ownership shared by all MCP processes. The kernel releases it on a crash;
/// the lock file must never be unlinked while another process may be opening it.
final class SessionDeviceClaim: Sendable {
    private let descriptor: Mutex<Int32>

    init(deviceID: String, store: DeviceLeaseStore) throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let path = store.fileURL(deviceID: deviceID).appendingPathExtension("session-lock").path
        let file = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
            close(file)
            throw AmooError.commandFailed(
                command: "start_session",
                output: "Device \(deviceID) is owned by another active session."
                    + " End that session or select another device."
            )
        }
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
