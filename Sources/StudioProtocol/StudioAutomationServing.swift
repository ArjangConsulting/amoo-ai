import Foundation

public protocol StudioAutomationServing: Sendable {
    func execute(_ request: StudioReplRequest) async throws -> StudioReplResult
    func run(_ request: StudioTestRunRequest) async throws -> StudioTestRunResult
    func reports() async -> StudioReportListResult
    func start(_ request: StudioTestRunRequest) async -> StudioTestStartResult
    func status(runId: String) async throws -> StudioTestRunStatus
    func cancel(runId: String) async throws -> StudioTestRunStatus
    func export(_ request: StudioTestExportRequest) async throws -> StudioTestExportResult
    /// The tool catalog, or nil when this build has none, which also disables completion.
    func toolCatalog() async -> StudioToolCatalog?
    func complete(_ request: StudioReplCompletionRequest) async throws -> StudioReplCompletionResult
    func validate(_ request: StudioReplValidationRequest) async throws -> StudioReplValidationResult
    /// Whether `generate` is available, which decides the `tests.generate` capability.
    func canGenerateTests() async -> Bool
    func generate(_ request: StudioTestGenerateRequest) async throws -> StudioTestGenerateResult
    /// Whether console commands can be recorded into sessions, which decides `repl.recording`.
    func canRecord() async -> Bool
    func startRecording(_ request: StudioReplRecordingStartRequest) async throws -> StudioReplRecording
    func stopRecording(_ request: StudioReplRecordingStopRequest) async throws -> StudioReplRecording
    /// Ends every recording, so their sessions are written when Studio disconnects.
    func stopAllRecordings() async
}

public extension StudioAutomationServing {
    func export(_ request: StudioTestExportRequest) async throws -> StudioTestExportResult {
        throw StudioAutomationError.invalidTest("Code export is unavailable in this Amoo build.")
    }

    func toolCatalog() async -> StudioToolCatalog? {
        nil
    }

    func complete(_ request: StudioReplCompletionRequest) async throws -> StudioReplCompletionResult {
        .empty(at: request.cursor)
    }

    func validate(_: StudioReplValidationRequest) async throws -> StudioReplValidationResult {
        .init(diagnostics: [])
    }

    func canGenerateTests() async -> Bool {
        false
    }

    func generate(_: StudioTestGenerateRequest) async throws -> StudioTestGenerateResult {
        throw StudioAutomationError.invalidTest("Test generation is unavailable in this Amoo build.")
    }

    func canRecord() async -> Bool {
        false
    }

    func startRecording(_: StudioReplRecordingStartRequest) async throws -> StudioReplRecording {
        throw StudioAutomationError.invalidTest("Console recording is unavailable in this Amoo build.")
    }

    func stopRecording(_: StudioReplRecordingStopRequest) async throws -> StudioReplRecording {
        throw StudioAutomationError.invalidTest("Console recording is unavailable in this Amoo build.")
    }

    func stopAllRecordings() async {}
}
