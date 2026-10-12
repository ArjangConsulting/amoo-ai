import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Shared termination state lets output failure wake a reader whose client left stdin open.
final class MCPPipeLifetime: Sendable {
    private let state = Mutex<(stopped: Bool, error: (any Error)?)>((false, nil))

    func stop(_ error: (any Error)? = nil) {
        state.withLock {
            $0.stopped = true
            if $0.error == nil {
                $0.error = error
            }
        }
    }

    func check() throws -> Bool {
        try state.withLock {
            if let error = $0.error {
                throw error
            }
            return !$0.stopped
        }
    }
}

/// Serial, bounded output on a dedicated worker. No pipe write holds the request actor.
final class MCPPipeWriter: Sendable {
    private let queue = DispatchQueue(label: "amoo.mcp.output")
    private let pendingBytes = Mutex(0)
    private let descriptor: Int32
    private let lifetime: MCPPipeLifetime
    private let timeout: Swift.Duration
    private let originalFlags: Int32

    init(output: FileHandle, lifetime: MCPPipeLifetime, timeout: Swift.Duration = .seconds(5)) {
        descriptor = dup(output.fileDescriptor)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        self.lifetime = lifetime
        self.timeout = timeout
        originalFlags = fcntl(descriptor, F_GETFL)
        if originalFlags >= 0 {
            _ = fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK)
        }
    }

    deinit {
        if originalFlags >= 0 {
            _ = fcntl(descriptor, F_SETFL, originalFlags)
        }
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    func write(_ data: Data) async throws {
        let accepted = pendingBytes.withLock { bytes in
            guard data.count <= 16 * 1024 * 1024 - bytes else { return false }
            bytes += data.count
            return true
        }
        guard accepted else {
            lifetime.stop(POSIXError(.ENOBUFS))
            throw POSIXError(.ENOBUFS)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                defer { pendingBytes.withLock { $0 -= data.count } }
                do {
                    try writeFrame(data)
                    continuation.resume()
                } catch {
                    lifetime.stop(error)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func writeFrame(_ data: Data) throws {
        let deadline = ContinuousClock.now + timeout
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                guard try lifetime.check() else { throw CancellationError() }
                guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pollDescriptor, 1, 100)
                if ready < 0, errno != EINTR {
                    throw POSIXError(.EIO)
                }
                guard ready > 0 else { continue }
                let count = systemWrite(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno != EINTR, errno != EAGAIN {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }
}

private func systemWrite(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(descriptor, bytes, count)
    #else
    Glibc.write(descriptor, bytes, count)
    #endif
}

/// Pull-based reading provides backpressure without dropping JSON-RPC frames.
func mcpInput(_ handle: FileHandle, lifetime: MCPPipeLifetime) -> AsyncThrowingStream<Data, any Error> {
    let worker = DispatchQueue(label: "amoo.mcp.input")
    return AsyncThrowingStream(unfolding: {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                worker.async {
                    do {
                        let data = try readMCPChunk(handle, lifetime: lifetime)
                        continuation.resume(returning: data)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { lifetime.stop() }
    })
}

private func readMCPChunk(_ handle: FileHandle, lifetime: MCPPipeLifetime) throws -> Data? {
    var bytes = [UInt8](repeating: 0, count: 65536)
    while try lifetime.check() {
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 100)
        if ready < 0, errno != EINTR {
            throw POSIXError(.EIO)
        }
        guard ready > 0 else { continue }
        let count = read(handle.fileDescriptor, &bytes, bytes.count)
        if count > 0 {
            return Data(bytes.prefix(count))
        }
        if count == 0 {
            return nil
        }
        if errno != EINTR, errno != EAGAIN {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    return nil
}
