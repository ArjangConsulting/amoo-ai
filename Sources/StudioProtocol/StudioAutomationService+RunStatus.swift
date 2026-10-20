import Foundation

/// Run-status bookkeeping for asynchronous test runs.
///
/// Split out of `StudioAutomationService.swift` to keep the actor within the size limits. Every
/// status change goes through `setStatus`, which also pushes it to Studio as `tests.progress`.
extension LiveStudioAutomationService {
    func updateProgress(runId: String?, operation: StudioToolOperation, current: Int, total: Int) {
        guard let runId else { return }
        setStatus(.init(
            runId: runId,
            state: .running,
            currentOperation: current,
            totalOperations: total,
            message: "Running \(operation.tool)…",
            sessionId: nil,
            reportId: nil
        ))
    }

    func finish(runId: String, result: StudioTestRunResult) {
        let reportStatus = storedReports.first { $0.id == result.reportId }?.status
        setStatus(.init(
            runId: runId,
            state: reportStatus == .passed ? .passed : .failed,
            currentOperation: runStatuses[runId]?.totalOperations ?? 0,
            totalOperations: runStatuses[runId]?.totalOperations ?? 0,
            message: result.message,
            sessionId: result.sessionId,
            reportId: result.reportId
        ))
        runTasks[runId] = nil
    }

    func markCancelled(runId: String) {
        guard runStatuses[runId]?.state == .running else { return }
        let previous = runStatuses[runId]!
        setStatus(.init(
            runId: runId,
            state: .cancelled,
            currentOperation: previous.currentOperation,
            totalOperations: previous.totalOperations,
            message: "Test run cancelled.",
            sessionId: nil,
            reportId: nil
        ))
        runTasks[runId] = nil
    }

    func markFailed(runId: String, message: String) {
        let previous = runStatuses[runId]
        setStatus(.init(
            runId: runId,
            state: .failed,
            currentOperation: previous?.currentOperation ?? 0,
            totalOperations: previous?.totalOperations ?? 0,
            message: message,
            sessionId: nil,
            reportId: nil
        ))
        runTasks[runId] = nil
    }

    /// Records a run's status and pushes it to Studio, so clients that advertise notifications
    /// never need to poll `tests.status`.
    func setStatus(_ status: StudioTestRunStatus) {
        runStatuses[status.runId] = status
        progressFeed.yield(status)
    }
}
