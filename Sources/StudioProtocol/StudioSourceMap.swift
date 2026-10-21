import AmooCore
import Foundation

/// The generated lines for one plan operation: 1-based and inclusive, as editors number lines.
public struct StudioSourceMapEntry: Codable, Equatable, Sendable {
    /// The operation's position in `compiledPlan.toolOperations`.
    public let operationIndex: Int
    /// The operation's id; for a compiled session `step-<n>`, where n is the recorded action's index.
    public let operationId: String
    public let startLine: Int
    public let endLine: Int

    public init(operationIndex: Int, operationId: String, startLine: Int, endLine: Int) {
        self.operationIndex = operationIndex
        self.operationId = operationId
        self.startLine = startLine
        self.endLine = endLine
    }
}

/// Generated test source together with where each plan operation landed in it.
public struct StudioGeneratedSource: Codable, Equatable, Sendable {
    public let fileName: String
    public let source: String
    /// `swift` or `kotlin`.
    public let language: String
    public let sourceMap: [StudioSourceMapEntry]

    public init(fileName: String, source: String, language: String, sourceMap: [StudioSourceMapEntry]) {
        self.fileName = fileName
        self.source = source
        self.language = language
        self.sourceMap = sourceMap
    }

    public static func language(forFileName fileName: String) -> String {
        fileName.hasSuffix(".kt") ? "kotlin" : fileName.hasSuffix(".swift") ? "swift" : "text"
    }
}

/// Finds each operation's statements in the final generated source.
///
/// Emitters build one statement per operation, then post-process the whole body: indent it,
/// insert `XCTFail` lines for excluded steps, and drop a wait that repeats the line before it.
/// Those passes only reindent, insert, or delete lines, so walking each operation's lines forward
/// through the final source, comparing without surrounding whitespace, recovers every span
/// without changing what the emitter produces.
public enum StudioSourceMapper {
    public static func map(statements: [String], operationIds: [String], in source: String) -> [StudioSourceMapEntry] {
        let finalLines = source.split(separator: "\n", omittingEmptySubsequences: false).map(normalized)
        var cursor = 0
        var entries: [StudioSourceMapEntry] = []
        for (index, statement) in statements.enumerated() {
            var matched: [Int] = []
            for line in statement.split(separator: "\n").map(normalized) where !line.isEmpty {
                if cursor < finalLines.count, finalLines[cursor] == line {
                    matched.append(cursor)
                    cursor += 1
                } else if isWait(line), cursor > 0, finalLines[cursor - 1] == line {
                    // Collapsed into the identical wait just before it.
                    continue
                } else if let found = finalLines[cursor...].firstIndex(of: line) {
                    matched.append(found)
                    cursor = found + 1
                }
            }
            if let first = matched.min(), let last = matched.max() {
                let id = index < operationIds.count ? operationIds[index] : "operation-\(index)"
                entries.append(.init(operationIndex: index, operationId: id, startLine: first + 1, endLine: last + 1))
            }
        }
        return entries
    }

    private static func normalized(_ line: Substring) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    private static func isWait(_ line: String) -> Bool {
        line.hasPrefix("waitForHittability(") || line.hasPrefix("waitForExistence(")
    }
}

public extension StudioCodeEmitting {
    /// Emitters that can report where operations land override this; the default maps nothing.
    func generateMapped(_ test: StudioAuthoredTest) throws -> StudioGeneratedSource {
        let result = try generate(test)
        return .init(
            fileName: result.fileName,
            source: result.source,
            language: StudioGeneratedSource.language(forFileName: result.fileName),
            sourceMap: []
        )
    }
}

// MARK: - tests.generate

/// Generates native test source from a recorded session's plan or an authored test.
public struct StudioTestGenerateRequest: Codable, Sendable {
    /// A session whose `plan.json` (or, when it has none, its compiled report) is the source.
    public let sessionId: String?
    /// An authored test, used when `sessionId` is absent.
    public let test: StudioAuthoredTest?
    public let uiToolkit: UIToolkit?
    public let testName: String?
    public let allowIncomplete: Bool?
    /// Where to look for `amoo.md` app context, searching upward; usually the app's project.
    public let projectPath: String?
    /// An explicit app-context file, overriding discovery.
    public let contextPath: String?

    public init(
        sessionId: String? = nil,
        test: StudioAuthoredTest? = nil,
        uiToolkit: UIToolkit? = nil,
        testName: String? = nil,
        allowIncomplete: Bool? = nil,
        projectPath: String? = nil,
        contextPath: String? = nil
    ) {
        self.sessionId = sessionId
        self.test = test
        self.uiToolkit = uiToolkit
        self.testName = testName
        self.allowIncomplete = allowIncomplete
        self.projectPath = projectPath
        self.contextPath = contextPath
    }
}

/// Why a plan could not be generated. `incomplete` can be overridden with `allowIncomplete`.
public struct StudioGenerationProblem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case incomplete
        case redacted
        case noEmitter
    }

    public let kind: Kind
    public let message: String
    public let warnings: [StudioPlanWarning]

    public init(kind: Kind, message: String, warnings: [StudioPlanWarning] = []) {
        self.kind = kind
        self.message = message
        self.warnings = warnings
    }
}

/// Generated source with its map, or the problem that stopped generation. `test` is the plan as
/// generated: app context applied, helpers bound, and every warning in `compiledPlan.warnings`.
public struct StudioTestGenerateResult: Codable, Sendable {
    public let generated: StudioGeneratedSource?
    public let problem: StudioGenerationProblem?
    public let test: StudioAuthoredTest

    public init(generated: StudioGeneratedSource?, problem: StudioGenerationProblem?, test: StudioAuthoredTest) {
        self.generated = generated
        self.problem = problem
        self.test = test
    }
}

/// Runs the shared generation pipeline. Implemented by the CLI, which owns the emitters and the
/// session store.
public protocol StudioTestGenerating: Sendable {
    func generate(_ request: StudioTestGenerateRequest) async throws -> StudioTestGenerateResult
}
