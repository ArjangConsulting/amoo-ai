import Foundation
import Synchronization

/// A monotonic request deadline propagated to RPC and subprocess transports.
public enum OperationDeadline {
    @TaskLocal public static var current: ContinuousClock.Instant?

    /// Restricts an existing transport timeout to the remaining request budget.
    public static func remaining(cappedAt timeout: Swift.Duration) -> Swift.Duration {
        guard let current else { return timeout }
        return max(.nanoseconds(1), min(timeout, ContinuousClock.now.duration(to: current)))
    }

    /// Bounds read-only work even if its backend does not promptly acknowledge cancellation.
    /// Never use this to release ownership of an in-flight device mutation.
    public static func read<Value: Sendable>(
        until deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let deadline = min(current ?? deadline, deadline)
        let race = DeadlineResult<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.attach(continuation)
                let operationTask = Task {
                    do {
                        try Task.checkCancellation()
                        guard ContinuousClock.now < deadline else { throw DeadlineExceeded() }
                        let result = try await $current.withValue(deadline, operation: operation)
                        try Task.checkCancellation()
                        guard ContinuousClock.now <= deadline else { throw DeadlineExceeded() }
                        race.finish(.success(result))
                    } catch { race.finish(.failure(error)) }
                }
                let timer = Task {
                    do {
                        try await Task.sleep(until: deadline, clock: .continuous)
                        race.finish(.failure(DeadlineExceeded()))
                    } catch { /* The other branch completed. */ }
                }
                race.setTasks([operationTask, timer])
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    public struct DeadlineExceeded: Error, Sendable, CustomStringConvertible {
        public var description: String {
            "Operation deadline exceeded"
        }

        public init() {}
    }
}

private final class DeadlineResult<Value: Sendable>: Sendable {
    private struct State {
        var result: Result<Value, any Error>?
        var continuation: CheckedContinuation<Value, any Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func attach(_ continuation: CheckedContinuation<Value, any Error>) {
        let result = state.withLock { state -> Result<Value, any Error>? in
            if let result = state.result {
                return result
            }
            state.continuation = continuation
            return nil
        }
        if let result {
            continuation.resume(with: result)
        }
    }

    func setTasks(_ tasks: [Task<Void, Never>]) {
        let finished = state.withLock { state in
            if state.result != nil {
                return true
            }
            state.tasks = tasks
            return false
        }
        if finished {
            tasks.forEach { $0.cancel() }
        }
    }

    func finish(_ result: Result<Value, any Error>) {
        let completion = state.withLock { state -> (CheckedContinuation<Value, any Error>?, [Task<Void, Never>]) in
            guard state.result == nil else { return (nil, []) }
            state.result = result
            let completion = (state.continuation, state.tasks)
            state.continuation = nil
            state.tasks = []
            return completion
        }
        completion.1.forEach { $0.cancel() }
        completion.0?.resume(with: result)
    }
}
