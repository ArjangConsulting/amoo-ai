import AmooCore
import Foundation
import SessionCompiler
import StudioProtocol
import TestCodeGenerator
import TestSession

/// Serves `tests.generate` and `tests.export` through the same pipeline as `amoo generate test`.
struct CLIStudioTestGenerator: StudioTestGenerating {
    let pipeline: StudioTestGenerationPipeline
    var store = FileSessionStore()

    func generate(_ request: StudioTestGenerateRequest) async throws -> StudioTestGenerateResult {
        let source = try await sourceTest(for: request)
        let prepared = try pipeline.prepare(
            source,
            contextPath: request.contextPath,
            discoveryDirectory: Self.discoveryDirectory(request.projectPath),
            testName: request.testName
        )
        do {
            let emitter = try pipeline.emitter(for: prepared, toolkit: request.uiToolkit)
            try pipeline.checkCompleteness(prepared, allowIncomplete: request.allowIncomplete ?? false)
            return try .init(generated: emitter.generateMapped(prepared), problem: nil, test: prepared)
        } catch let error as StudioGenerationError {
            return .init(generated: nil, problem: Self.problem(error), test: prepared)
        }
    }

    /// An authored test as given; for a session, its `plan.json`, or its report compiled now when the
    /// session ended without writing one.
    private func sourceTest(for request: StudioTestGenerateRequest) async throws -> StudioAuthoredTest {
        if let test = request.test {
            return test
        }
        guard let sessionID = request.sessionId, !sessionID.isEmpty else {
            throw StudioAutomationError.invalidTest("Provide a session or a test to generate from.")
        }
        let planURL = store.directory(for: sessionID).appending(path: "plan.json")
        if let data = try? Data(contentsOf: planURL) {
            return try JSONDecoder().decode(StudioAuthoredTest.self, from: data)
        }
        guard let report = await store.loadReport(sessionID: sessionID) else {
            throw StudioAutomationError.invalidTest("No recorded session \(sessionID) was found.")
        }
        return try SessionPlanCompiler.compile(report: report, testName: request.testName, testDescription: nil)
            .studioTest
    }

    /// `amoo.md` is searched upward from the app's project, or from the working directory without one.
    static func discoveryDirectory(_ projectPath: String?) -> URL {
        guard let projectPath, !projectPath.isEmpty else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        let url = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        // An .xcodeproj or .xcworkspace is a directory, but amoo.md sits beside it.
        let isPackage = ["xcodeproj", "xcworkspace"].contains(url.pathExtension)
        return exists && isDirectory.boolValue && !isPackage ? url : url.deletingLastPathComponent()
    }

    static func problem(_ error: StudioGenerationError) -> StudioGenerationProblem {
        switch error {
        case .noEmitter: .init(kind: .noEmitter, message: error.description)
        case let .incomplete(warnings): .init(kind: .incomplete, message: error.description, warnings: warnings)
        case let .redacted(warnings): .init(kind: .redacted, message: error.description, warnings: warnings)
        }
    }
}
