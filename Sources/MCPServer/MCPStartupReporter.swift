import AmooCore
import Foundation
import MCP

/// Serializes monotonic MCP progress counters, including heartbeats during silent toolchain waits.
actor MCPStartupReporter {
    private let runtime: MCPRequestRuntime
    private let token: Value?
    private let started = ContinuousClock.now
    private var count = 0
    private var latest: String?

    init(runtime: MCPRequestRuntime, token: Value?) {
        self.runtime = runtime
        self.token = token
    }

    func report(_ message: String) async {
        latest = message
        await send(message)
    }

    func heartbeat() async {
        guard let latest else { return }
        let elapsed = Int(started.duration(to: .now).components.seconds)
        await send("\(latest) — \(elapsed)s elapsed; startup is still pending.")
    }

    private func send(_ message: String) async {
        guard let token else { return }
        count += 1
        let notification = Value.object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/progress"),
            "params": .object([
                "progressToken": token,
                "progress": .int(count),
                "message": .string(message)
            ])
        ])
        guard var data = try? JSONEncoder().encode(notification) else { return }
        data.append(0x0A)
        await runtime.write(data)
    }
}

/// Keep heartbeats scoped to a single request, and cancel them before returning its response.
func withMCPStartupProgress(
    runtime: MCPRequestRuntime,
    token: Value?,
    operation: @escaping @Sendable () async -> Data?
) async -> Data? {
    let progress = MCPStartupReporter(runtime: runtime, token: token)
    let reporter: @Sendable (String) async -> Void = { message in await progress.report(message) }
    return await StartupProgress.$reporter.withValue(reporter) {
        let heartbeat = Task {
            do {
                while true {
                    try await Task.sleep(for: .seconds(10))
                    await progress.heartbeat()
                }
            } catch { /* Request completed or cancelled. */ }
        }
        let result = await operation()
        heartbeat.cancel()
        await heartbeat.value
        return result
    }
}
