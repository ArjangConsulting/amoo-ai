import AmooCore
import Foundation
import StudioProtocol

/// Why a plan cannot be turned into a test. Descriptions are shown verbatim by `amoo generate test`
/// and by Studio.
public enum StudioGenerationError: Error, CustomStringConvertible, Equatable {
    case noEmitter(platform: String, toolkit: String)
    case incomplete([StudioPlanWarning])
    case redacted([StudioPlanWarning])

    public var description: String {
        switch self {
        case let .noEmitter(platform, toolkit):
            return "No code generator available for platform '\(platform)' and toolkit '\(toolkit)'."
        case let .incomplete(excluded):
            let details = excluded
                .map { "  - step \($0.actionIndex) (\($0.toolName)): \($0.reason)" }
                .joined(separator: "\n")
            return """
            This plan has \(excluded.count) step(s) that could not be compiled, so generating from it \
            would produce an incomplete test:
            \(details)

            Re-record without those steps, or pass --allow-incomplete to generate anyway.
            """
        case let .redacted(redacted):
            let details = redacted
                .map { "  - step \($0.actionIndex) (\($0.toolName)): \($0.reason)" }
                .joined(separator: "\n")
            return """
            This plan contains \(redacted.count) redacted value(s), so generation would emit
            placeholders as executable input:
            \(details)

            Replace each value with an approved fixture or a named context helper, then generate again.
            """
        }
    }
}

/// The one path from a compiled plan to native test source, shared by `amoo generate test` and
/// Studio's `tests.generate`: app context, validation, naming, helper binding, completeness checks,
/// and emission.
public struct StudioTestGenerationPipeline: Sendable {
    private let emitters: StudioCodeEmitters

    public init(emitters: StudioCodeEmitters) {
        self.emitters = emitters
    }

    /// Applies app context (an explicit file, else `amoo.md` discovered upward from
    /// `discoveryDirectory`), validates it, renames the test, and binds context helpers.
    public func prepare(
        _ test: StudioAuthoredTest,
        contextPath: String?,
        discoveryDirectory: URL,
        testName: String?
    ) throws -> StudioAuthoredTest {
        var prepared: StudioAuthoredTest = if let contextPath {
            try test.replacingTestContext(RepositoryTestProfile.load(
                URL(fileURLWithPath: (contextPath as NSString).expandingTildeInPath),
                platform: test.platform
            ))
        } else if test.testContext == nil,
                  let context = try RepositoryTestProfile.discover(from: discoveryDirectory, platform: test.platform) {
            test.replacingTestContext(context)
        } else {
            test
        }
        if let context = prepared.testContext {
            try RepositoryTestProfile.validate(context, platform: prepared.platform)
        }
        if let testName {
            prepared = prepared.replacingName(testName)
        }
        // The session compiler never sets `helper`, so without this a context file's helpers would
        // only ever apply to hand-authored plans.
        return HelperBinder.bindingContextHelpers(prepared)
    }

    public func emitter(for test: StudioAuthoredTest, toolkit: UIToolkit?) throws -> any StudioCodeEmitting {
        let toolkit = toolkit ?? test.requirements?.uiToolkit ?? .view
        guard let emitter = emitters.emitter(for: test.platform, toolkit: toolkit) else {
            throw StudioGenerationError.noEmitter(platform: test.platform.rawValue, toolkit: toolkit.rawValue)
        }
        return emitter
    }

    /// Refuses a plan whose recorded steps did not all compile, unless the caller accepts a partial
    /// test, and always refuses redacted values, which would run as placeholder input.
    public func checkCompleteness(_ test: StudioAuthoredTest, allowIncomplete: Bool) throws {
        let excluded = test.compiledPlan?.excludedWarnings ?? []
        if !excluded.isEmpty, !allowIncomplete {
            throw StudioGenerationError.incomplete(excluded)
        }
        let redacted = (test.compiledPlan?.warnings ?? []).filter { $0.kind == .redacted }
        if !redacted.isEmpty {
            throw StudioGenerationError.redacted(redacted)
        }
    }

    /// Prepares, checks, and emits `test` with its source map.
    public func generate(
        _ test: StudioAuthoredTest,
        contextPath: String? = nil,
        discoveryDirectory: URL,
        testName: String? = nil,
        toolkit: UIToolkit? = nil,
        allowIncomplete: Bool = false
    ) throws -> (test: StudioAuthoredTest, source: StudioGeneratedSource) {
        let prepared = try prepare(
            test,
            contextPath: contextPath,
            discoveryDirectory: discoveryDirectory,
            testName: testName
        )
        let emitter = try emitter(for: prepared, toolkit: toolkit)
        try checkCompleteness(prepared, allowIncomplete: allowIncomplete)
        return try (prepared, emitter.generateMapped(prepared))
    }
}
