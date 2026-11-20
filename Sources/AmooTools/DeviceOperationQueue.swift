// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
import Tracing

/// FIFO per device. Queued cancellation returns immediately; active work retains ownership
/// until it has actually stopped, even when its backend ignores cancellation.
actor DeviceOperationQueue {
    private struct Pending {
        let key: String
        let owner: String?
        let operation: @Sendable () async -> ToolResult
        let continuation: CheckedContinuation<ToolResult, Never>
        var task: Task<Void, Never>?
    }

    private var pending: [UUID: Pending] = [:]
    private var queues: [String: [UUID]] = [:]
    private var running = Set<String>()

    func cancel(key: String, owner: String? = nil) {
        let ids = pending.filter { $0.value.key == key && (owner == nil || $0.value.owner == owner) }.map(\.key)
        for id in ids {
            cancel(id: id)
        }
    }

    private func cancel(id: UUID) {
        guard let entry = pending[id] else { return }
        if let task = entry.task {
            task.cancel()
        } else {
            pending[id] = nil
            queues[entry.key]?.removeAll { $0 == id }
            entry.continuation.resume(returning: Self.cancelledResult)
        }
    }

    func run(
        key: String,
        owner: String? = nil,
        operation: @escaping @Sendable () async -> ToolResult
    ) async -> ToolResult {
        let id = UUID()
        let queuedAt = DefaultTracerClock.now
        let parentContext = InstrumentationContext.current ?? .topLevel
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: Self.cancelledResult)
                    return
                }
                pending[id] = Pending(key: key, owner: owner, operation: {
                    // The operation runs on the queue's own task; carry the caller's trace into it
                    // and record how long the call waited for the device.
                    InstrumentationSystem.tracer
                        .startSpan("device_queue.wait", context: parentContext, at: queuedAt)
                        .end()
                    return await InstrumentationContext.$current.withValue(parentContext) {
                        await operation()
                    }
                }, continuation: continuation)
                queues[key, default: []].append(id)
                startNext(key)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func startNext(_ key: String) {
        guard !running.contains(key), let id = queues[key]?.first, let entry = pending[id] else { return }
        queues[key]?.removeFirst()
        running.insert(key)
        pending[id]?.task = Task {
            let result = Task.isCancelled ? Self.cancelledResult : await entry.operation()
            pending.removeValue(forKey: id)?.continuation.resume(returning: result)
            running.remove(key)
            if queues[key]?.isEmpty == true {
                queues[key] = nil
            }
            startNext(key)
        }
    }

    private static var cancelledResult: ToolResult {
        ToolExecutionError(code: "cancelled", message: "Operation cancelled before execution.").result
    }
}

// swiftlint:enable multiline_arguments
