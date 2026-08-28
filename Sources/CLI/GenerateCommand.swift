import AmooCore
import Foundation
import StudioProtocol
import TestCodeGenerator

public enum GenerateCommandParseError: Error, CustomStringConvertible {
    case usage
    case missingValue(flag: String)
    case unexpectedArgument(String)
    case invalidValue(flag: String, value: String, allowed: [String])

    public var description: String {
        switch self {
        case .usage:
            renderGenerateHelp()
        case let .missingValue(flag):
            "Missing value for \(flag)."
        case let .unexpectedArgument(arg):
            "Unexpected argument '\(arg)'."
        case let .invalidValue(flag, value, allowed):
            "Invalid value '\(value)' for \(flag). Expected one of: \(allowed.joined(separator: ", "))."
        }
    }
}

func renderGenerateHelp() -> String {
    """
    Usage: amoo generate test --plan <path-to-authored-test.json> [--out <directory>]
                             [--context <path-to-test-context.json>]
                             [--ui-toolkit <view|compose>] [--allow-incomplete]

      Emits a skeleton test. Review the compiled-plan warnings and finalize it against your
      project's conventions — identifier catalog, naming, test tier, dropped assertions — before
      committing.

      --plan              Path to the authored/compiled test JSON.
      --out               Directory to write the generated file into. Prints to stdout if omitted.
      --context           App-owned test context JSON. Overrides testContext embedded in the plan.
      --ui-toolkit        Override the plan's UI toolkit (defaults to its requirement, then view).
      --allow-incomplete  Generate even though the plan records steps that could not be compiled.
                          Without this, generation stops rather than emitting a test missing steps.
    """
}

public struct GenerateTestOptions: Sendable, Equatable {
    public var planPath: String
    public var outputDirectory: String?
    public var allowIncomplete: Bool
    public var uiToolkit: UIToolkit?
    public var contextPath: String?

    public init(
        planPath: String,
        outputDirectory: String?,
        allowIncomplete: Bool = false,
        uiToolkit: UIToolkit? = nil,
        contextPath: String? = nil
    ) {
        self.planPath = planPath
        self.outputDirectory = outputDirectory
        self.allowIncomplete = allowIncomplete
        self.uiToolkit = uiToolkit
        self.contextPath = contextPath
    }
}

private func parseUIToolkit(flag: String, value: String) throws -> UIToolkit {
    guard let parsed = UIToolkit(rawValue: value.lowercased()) else {
        throw GenerateCommandParseError.invalidValue(
            flag: flag,
            value: value,
            allowed: UIToolkit.allCases.map(\.rawValue)
        )
    }
    return parsed
}

public func parseGenerateTestOptions(args: [String]) throws -> GenerateTestOptions {
    guard !args.isEmpty else { throw GenerateCommandParseError.usage }

    var planPath: String?
    var outputDirectory: String?
    var allowIncomplete = false
    var uiToolkit: UIToolkit?
    var contextPath: String?
    var index = 0

    while index < args.count {
        let flag = args[index]
        guard flag.hasPrefix("--") else { throw GenerateCommandParseError.unexpectedArgument(flag) }

        // Valueless flags are handled before the value lookup so they don't consume the next argument.
        if flag == "--allow-incomplete" {
            allowIncomplete = true
            index += 1
            continue
        }

        let valueIndex = index + 1
        guard valueIndex < args.count else { throw GenerateCommandParseError.missingValue(flag: flag) }
        let value = args[valueIndex]
        switch flag {
        case "--plan": planPath = value
        case "--out": outputDirectory = value
        case "--ui-toolkit": uiToolkit = try parseUIToolkit(flag: flag, value: value)
        case "--context": contextPath = value
        default: throw GenerateCommandParseError.unexpectedArgument(flag)
        }
        index += 2
    }

    guard let planPath else { throw GenerateCommandParseError.missingValue(flag: "--plan") }
    return GenerateTestOptions(
        planPath: planPath,
        outputDirectory: outputDirectory,
        allowIncomplete: allowIncomplete,
        uiToolkit: uiToolkit,
        contextPath: contextPath
    )
}

public func runGenerateTestCommand(
    options: GenerateTestOptions,
    emitters: StudioCodeEmitters
) throws -> CLIResult {
    let data = try Data(contentsOf: URL(fileURLWithPath: options.planPath))
    let decodedTest = try JSONDecoder().decode(StudioAuthoredTest.self, from: data)
    var test: StudioAuthoredTest
    if let contextPath = options.contextPath {
        let contextData = try Data(contentsOf: URL(fileURLWithPath: contextPath))
        test = try decodedTest.replacingTestContext(JSONDecoder().decode(StudioTestContext.self, from: contextData))
    } else {
        test = decodedTest
    }
    // Bind operations to declared helpers whose call shape matches. The session compiler never sets
    // `helper`, so without this a context file's helpers only ever applied to hand-authored plans.
    test = HelperBinder.bindingContextHelpers(test)
    let toolkit = options.uiToolkit ?? test.requirements?.uiToolkit ?? .view
    let emitter = emitters.emitter(for: test.platform, toolkit: toolkit)
    guard let emitter else {
        return CLIResult(
            output: "No code generator available for platform '\(test.platform.rawValue)'"
                + " and toolkit '\(toolkit.rawValue)'.",
            exitCode: 64
        )
    }

    // A plan can record steps that never made it into toolOperations. Generating anyway would
    // produce a test that is silently missing actions and then fails for reasons that point
    // nowhere near the real cause, so stop unless the caller explicitly accepts a partial test.
    let excluded = test.compiledPlan?.excludedWarnings ?? []
    if !excluded.isEmpty, options.allowIncomplete == false {
        let details = excluded
            .map { "  - step \($0.actionIndex) (\($0.toolName)): \($0.reason)" }
            .joined(separator: "\n")
        return CLIResult(
            output: """
            This plan has \(excluded.count) step(s) that could not be compiled, so generating from it \
            would produce an incomplete test:
            \(details)

            Re-record without those steps, or pass --allow-incomplete to generate anyway.
            """,
            exitCode: 65
        )
    }

    let generated = try emitter.generate(test)

    guard let outputDirectory = options.outputDirectory else {
        return CLIResult(output: generated.source, exitCode: 0)
    }

    let directoryURL = URL(fileURLWithPath: outputDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let fileURL = directoryURL.appendingPathComponent(generated.fileName)
    try generated.source.write(to: fileURL, atomically: true, encoding: .utf8)
    return CLIResult(output: "Wrote \(fileURL.path)", exitCode: 0)
}
