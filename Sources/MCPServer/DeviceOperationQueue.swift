import Foundation

/// FIFO execution per physical device. A cancelled waiter never invokes its operation, and
/// cancellation propagates into the running operation without releasing the device early.
actor DeviceOperationQueue {
    private struct Pending {
        let id: UUID
        let task: Task<ToolResult, Never>
        let owner: String?
    }

    private var tails: [String: Pending] = [:]
    private var operations: [String: [UUID: Pending]] = [:]

    /// Cancel active and queued work without waiting behind a stalled device operation.
    func cancel(key: String, owner: String? = nil) {
        for operation in operations[key]?.values ?? [:].values where owner == nil || operation.owner == owner {
            operation.task.cancel()
        }
    }

    func run(
        key: String,
        owner: String? = nil,
        operation: @escaping @Sendable () async -> ToolResult
    ) async -> ToolResult {
        // The inner task is unstructured, so the caller's cancellation only reaches it through
        // `onCancel` below — which can land after the task has already passed its own check.
        // Refuse an already-cancelled caller here so its operation can never start.
        guard !Task.isCancelled else { return Self.cancelledResult }
        let previous = tails[key]?.task
        let id = UUID()
        let task = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return Self.cancelledResult }
            return await operation()
        }
        tails[key] = Pending(id: id, task: task, owner: owner)
        operations[key, default: [:]][id] = Pending(id: id, task: task, owner: owner)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        operations[key]?[id] = nil
        if operations[key]?.isEmpty == true {
            operations[key] = nil
        }
        if tails[key]?.id == id {
            tails.removeValue(forKey: key)
        }
        return result
    }

    private static var cancelledResult: ToolResult {
        ToolExecutionError(code: "cancelled", message: "Operation cancelled before execution.").result
    }
}
