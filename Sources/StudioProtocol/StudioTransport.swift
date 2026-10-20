import AmooLogging
import Foundation

/// Pushes JSON-RPC notifications (messages with a `method` and no `id`) to the connected Studio.
///
/// Posts made before `StudioService.run` attaches a transport, or after it detaches, are dropped:
/// notifications describe live progress, and nothing replays them to a client that is not there.
/// Protocols that must survive gaps carry sequence numbers and offer a replay method.
public actor StudioNotificationCenter {
    public typealias Sink = @Sendable (Data) async -> Void

    private let logger = AmooLogger.forType(StudioNotificationCenter.self)
    private var sink: Sink?

    public init() {}

    /// Encodes and sends one notification. Encoding failures are logged and dropped rather than
    /// thrown: a missed progress event must never fail the operation that produced it.
    public func post(method: String, params: some Encodable & Sendable) async {
        guard let sink else { return }
        do {
            let body = try JSONEncoder().encode(StudioNotification(method: method, params: params))
            await sink(body)
        } catch {
            logger.error("Could not encode notification", error: error, context: "method=\(method)")
        }
    }

    func attach(_ sink: @escaping Sink) {
        self.sink = sink
    }

    func detach() {
        sink = nil
    }
}

private struct StudioNotification<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: Params
}

/// Orders work per device.
///
/// `StudioService` answers requests concurrently, so two operations that drive the same device
/// could otherwise interleave their gestures. Work on one device runs in arrival order; work on
/// different devices, and work with no device, runs in parallel.
public actor StudioDeviceLocks {
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Runs `operation` while holding `deviceId`'s lock, or immediately when `deviceId` is `nil`.
    nonisolated public func withDevice<Value: Sendable>(
        _ deviceId: String?,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let deviceId else { return try await operation() }
        await acquire(deviceId)
        do {
            let value = try await operation()
            await release(deviceId)
            return value
        } catch {
            await release(deviceId)
            throw error
        }
    }

    private func acquire(_ deviceId: String) async {
        if held.insert(deviceId).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[deviceId, default: []].append(continuation)
        }
    }

    /// Hands the lock straight to the next waiter, so the device never looks free in between and a
    /// newcomer cannot jump the queue.
    private func release(_ deviceId: String) {
        guard var queue = waiters[deviceId], queue.isEmpty == false else {
            held.remove(deviceId)
            return
        }
        let next = queue.removeFirst()
        waiters[deviceId] = queue.isEmpty ? nil : queue
        next.resume()
    }
}

/// Serializes frame writes so concurrent responses and notifications never interleave bytes.
actor StudioFrameWriter {
    private let output: FileHandle

    init(output: FileHandle) {
        self.output = output
    }

    func write(_ body: Data) throws {
        try ContentLengthFraming.writeMessage(body, to: output)
    }
}

extension ContentLengthFraming {
    /// Reads frames on a dedicated thread. `FileHandle` reads block, and parking a Swift
    /// concurrency thread for the life of the process would starve request handlers. The stream
    /// finishes at end of input or on the first malformed frame.
    static func frames(from input: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let reader = Thread {
                while let frame = try? readMessage(from: input) {
                    continuation.yield(frame)
                }
                continuation.finish()
            }
            reader.name = "amoo.studio.reader"
            reader.start()
        }
    }
}
