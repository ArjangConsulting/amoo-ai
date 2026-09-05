import Foundation

/// FIFO execution per physical device. A cancelled waiter never invokes its operation, and
/// cancellation propagates into the running operation without releasing the device early.
actor DeviceOperationQueue {
    private struct Pending {
        let id: UUID
        let task: Task<ToolResult, Never>
    }

    private var tails: [String: Pending] = [:]

    func run(key: String, operation: @escaping @Sendable () async -> ToolResult) async -> ToolResult {
        let previous = tails[key]?.task
        let id = UUID()
        let task = Task {
            _ = await previous?.value
            guard !Task.isCancelled else {
                return ToolExecutionError(code: "cancelled", message: "Operation cancelled before execution.").result
            }
            return await operation()
        }
        tails[key] = Pending(id: id, task: task)
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if tails[key]?.id == id {
            tails.removeValue(forKey: key)
        }
        return result
    }
}
