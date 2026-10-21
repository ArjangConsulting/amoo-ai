import Foundation

/// Test generation and export. Split out of `StudioAutomationService.swift` to keep the actor within
/// the size limits.
public extension LiveStudioAutomationService {
    func canGenerateTests() -> Bool {
        testGenerator != nil
    }

    func generate(_ request: StudioTestGenerateRequest) async throws -> StudioTestGenerateResult {
        guard let testGenerator else {
            throw StudioAutomationError.invalidTest("Test generation is unavailable in this Amoo build.")
        }
        return try await testGenerator.generate(request)
    }

    /// With a generator, export runs the shared pipeline, so it applies the same app context and
    /// completeness checks as `amoo generate test`.
    func export(_ request: StudioTestExportRequest) async throws -> StudioTestExportResult {
        if let testGenerator {
            let test = request.testContext.map(request.test.replacingTestContext) ?? request.test
            let result = try await testGenerator.generate(.init(test: test))
            if let problem = result.problem {
                throw StudioAutomationError.invalidTest(problem.message)
            }
            guard let generated = result.generated
            else { throw StudioAutomationError.invalidTest("Code export failed.") }
            return .init(fileName: generated.fileName, source: generated.source)
        }
        let test = request.testContext.map(request.test.replacingTestContext) ?? request.test
        let toolkit = test.requirements?.uiToolkit ?? .view
        let emitter = codeEmitters.emitter(for: test.platform, toolkit: toolkit)
        guard let emitter else {
            throw StudioAutomationError.invalidTest(
                "Code export is unavailable for platform '\(test.platform.rawValue)'"
                    + " and toolkit '\(toolkit.rawValue)'."
            )
        }
        do {
            return try emitter.generate(test)
        } catch {
            throw StudioAutomationError.invalidTest("Code export failed: \(error)")
        }
    }
}
