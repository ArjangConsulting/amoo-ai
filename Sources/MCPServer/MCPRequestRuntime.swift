import AmooCore
import Foundation

/// Tracks requests independently of slow output and reserves capacity for recovery calls.
actor MCPRequestRuntime {
    private var requests: [String: Task<Void, Never>] = [:]
    private var regularRequests = Set<String>()
    private var writeError: (any Error)?
    private let writer: MCPPipeWriter
    let lifetime: MCPPipeLifetime

    init(output: FileHandle, lifetime: MCPPipeLifetime = MCPPipeLifetime()) {
        self.lifetime = lifetime
        writer = MCPPipeWriter(output: output, lifetime: lifetime)
    }

    func submit(id: String, control: Bool = false, operation: @escaping @Sendable () async -> Data?) -> Bool {
        guard requests[id] == nil, requests.count < 72, control || regularRequests.count < 64 else { return false }
        if !control {
            regularRequests.insert(id)
        }
        requests[id] = Task {
            await PerformanceTelemetry.$traceID.withValue(UUID().uuidString) {
                let start = ContinuousClock.now
                if let data = await operation() {
                    await write(data)
                }
                PerformanceTelemetry.record("mcp_request", operation: "complete", duration: start.duration(to: .now))
            }
            requests.removeValue(forKey: id)
            regularRequests.remove(id)
        }
        return true
    }

    func contains(id: String) -> Bool {
        requests[id] != nil
    }

    func cancelAll() {
        requests.values.forEach { $0.cancel() }
    }

    func cancel(id: String) {
        requests[id]?.cancel()
    }

    func write(_ data: Data) async {
        let start = ContinuousClock.now
        defer {
            PerformanceTelemetry.record(
                "mcp_output",
                operation: "write",
                duration: start.duration(to: .now),
                metadata: ["bytes": String(data.count)]
            )
        }
        do { try await writer.write(data) } catch {
            if writeError == nil {
                MCPTransportDiagnostics().emit("output_error")
            }
            writeError = error
            cancelAll()
        }
    }

    /// Allows already submitted responses to finish, then cancels without an unbounded join.
    func drain(grace: Swift.Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock.now + grace
        while !requests.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled, writeError == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !requests.isEmpty {
            cancelAll()
            lifetime.stop()
        }
        if let writeError {
            throw writeError
        }
    }

    nonisolated static func input(_ handle: FileHandle) -> AsyncThrowingStream<Data, any Error> {
        mcpInput(handle, lifetime: MCPPipeLifetime())
    }

    enum InputError: Error { case backpressure, oversizedFrame }
}
