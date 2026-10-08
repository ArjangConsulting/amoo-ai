#if os(macOS)
import Darwin
import Foundation

/// Cross-process lock for the shared iOS DerivedData directory. Kernel ownership is released on exit.
final class CompanionBuildLock: @unchecked Sendable {
    private var descriptor: Int32
    private let mutex = NSLock()

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(directory: String, timeout: Duration = .seconds(300)) async throws -> CompanionBuildLock {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let descriptor = open(directory + "/.amoo-build.lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CompanionError.buildFailed("Cannot open shared companion build lock") }
        let deadline = ContinuousClock.now + timeout
        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN else {
                    throw CompanionError.buildFailed("Cannot acquire shared companion build lock")
                }
                guard ContinuousClock.now < deadline else {
                    throw CompanionError.buildFailed("Timed out waiting for another companion build")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            close(descriptor)
            throw error
        }
        return CompanionBuildLock(descriptor: descriptor)
    }

    func release() {
        mutex.withLock {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }
}
#endif
