import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Tracks cancellable requests and serializes complete output frames. Blocking input runs on a
/// dedicated Dispatch worker so it never holds a Swift cooperative executor thread.
actor MCPRequestRuntime {
    private var requests: [String: Task<Void, Never>] = [:]
    private var writeError: (any Error)?
    private let output: FileHandle

    init(output: FileHandle) {
        self.output = output
    }

    func submit(id: String, operation: @escaping @Sendable () async -> Data?) -> Bool {
        guard requests[id] == nil, requests.count < 64 else { return false }
        requests[id] = Task {
            if let data = await operation() {
                write(data)
            }
            requests.removeValue(forKey: id)
        }
        return true
    }

    func cancelAll() {
        requests.values.forEach { $0.cancel() }
    }

    func cancel(id: String) {
        requests[id]?.cancel()
    }

    func write(_ data: Data) {
        do { try output.write(contentsOf: data) } catch { writeError = error }
    }

    func drain() async throws {
        while let task = requests.values.first {
            await task.value
        }
        if let writeError {
            throw writeError
        }
    }

    nonisolated static func input(_ handle: FileHandle) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            DispatchQueue(label: "amoo.mcp.input").async {
                do {
                    while let data = try readAvailable(handle) {
                        switch continuation.yield(data) {
                        case .enqueued: break
                        case .dropped:
                            continuation.finish(throwing: InputError.backpressure)
                            return
                        case .terminated: return
                        @unknown default: return
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }

    // FileHandle.read(upToCount:) can wait to fill the requested count on a pipe.
    // A single POSIX read returns available bytes, allowing request/response clients to proceed.
    nonisolated private static func readAvailable(_ handle: FileHandle) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                return Data(bytes.prefix(count))
            }
            if count == 0 {
                return nil
            }
            if errno == EINTR {
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    enum InputError: Error { case backpressure, oversizedFrame }
}
