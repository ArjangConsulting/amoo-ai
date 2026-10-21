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
                             [--context <amoo.md|test-context.json>]
                             [--ui-toolkit <view|compose>] [--test-name <name>] [--allow-incomplete]

      Emits a skeleton test. Review the compiled-plan warnings and finalize it against your
      project's conventions — identifier catalog, naming, test tier, dropped assertions — before
      committing.

      --plan              Path to the authored/compiled test JSON.
      --out               Directory to write the generated file into. Prints to stdout if omitted.
      --context           App-owned JSON or Markdown profile with a fenced amoo-context JSON block.
                          Overrides testContext embedded in the plan. Prose-only Markdown is invalid.
      --ui-toolkit        Override the plan's UI toolkit (defaults to its requirement, then view).
      --test-name         Override the recorded/semantic test name; sanitized for generated code.
      --allow-incomplete  Generate even though the plan records steps that could not be compiled.
                          Without this, generation stops rather than emitting a test missing steps.

    To get a plan without recording a session, see `amoo generate plan --help`
    (`--report` recompiles a recorded report.json; `--from-flow` compiles a hand-written flow).
    """
}

public struct GenerateTestOptions: Sendable, Equatable {
    public var planPath: String
    public var outputDirectory: String?
    public var allowIncomplete: Bool
    public var uiToolkit: UIToolkit?
    public var contextPath: String?
    public var testName: String?

    public init(
        planPath: String,
        outputDirectory: String?,
        allowIncomplete: Bool = false,
        uiToolkit: UIToolkit? = nil,
        contextPath: String? = nil,
        testName: String? = nil
    ) {
        self.planPath = planPath
        self.outputDirectory = outputDirectory
        self.allowIncomplete = allowIncomplete
        self.uiToolkit = uiToolkit
        self.contextPath = contextPath
        self.testName = testName
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

    let parsed = try parseGenerateArguments(args)
    guard let planPath = parsed.planPath else { throw GenerateCommandParseError.missingValue(flag: "--plan") }
    return GenerateTestOptions(
        planPath: planPath,
        outputDirectory: parsed.outputDirectory,
        allowIncomplete: parsed.allowIncomplete,
        uiToolkit: parsed.uiToolkit,
        contextPath: parsed.contextPath,
        testName: parsed.testName
    )
}

private struct ParsedGenerateArguments {
    var planPath: String?
    var outputDirectory: String?
    var allowIncomplete = false
    var uiToolkit: UIToolkit?
    var contextPath: String?
    var testName: String?
}

private func parseGenerateArguments(_ args: [String]) throws -> ParsedGenerateArguments {
    var planPath: String?
    var outputDirectory: String?
    var allowIncomplete = false
    var uiToolkit: UIToolkit?
    var contextPath: String?
    var testName: String?
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
        case "--test-name": testName = value
        default: throw GenerateCommandParseError.unexpectedArgument(flag)
        }
        index += 2
    }

    return ParsedGenerateArguments(
        planPath: planPath,
        outputDirectory: outputDirectory,
        allowIncomplete: allowIncomplete,
        uiToolkit: uiToolkit,
        contextPath: contextPath,
        testName: testName
    )
}

public func runGenerateTestCommand(
    options: GenerateTestOptions,
    emitters: StudioCodeEmitters
) throws -> CLIResult {
    let data = try Data(contentsOf: URL(fileURLWithPath: options.planPath))
    let decodedTest = try JSONDecoder().decode(StudioAuthoredTest.self, from: data)
    let pipeline = StudioTestGenerationPipeline(emitters: emitters)
    let test = try pipeline.prepare(
        decodedTest,
        contextPath: options.contextPath,
        discoveryDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        testName: options.testName
    )
    let emitter: any StudioCodeEmitting
    do {
        emitter = try pipeline.emitter(for: test, toolkit: options.uiToolkit)
        // A plan can record steps that never made it into toolOperations, or carry redacted values.
        // Generating anyway would produce a test that fails for reasons that point nowhere near the
        // real cause, so stop unless the caller explicitly accepts a partial test.
        try pipeline.checkCompleteness(test, allowIncomplete: options.allowIncomplete)
    } catch let error as StudioGenerationError {
        if case .noEmitter = error {
            return CLIResult(output: error.description, exitCode: 64)
        }
        return CLIResult(output: error.description, exitCode: 65)
    }

    var exportedTest = test
    var generated = try emitter.generate(exportedTest)

    guard let outputDirectory = options.outputDirectory else {
        return CLIResult(output: generated.source, exitCode: 0)
    }

    let directoryURL = URL(fileURLWithPath: outputDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    var fileURL = directoryURL.appendingPathComponent(generated.fileName)
    var collisionSuffix = 2
    while FileManager.default.fileExists(atPath: fileURL.path) {
        exportedTest = test.replacingName("\(test.name) \(collisionSuffix)")
        generated = try emitter.generate(exportedTest)
        fileURL = directoryURL.appendingPathComponent(generated.fileName)
        collisionSuffix += 1
    }
    try generated.source.write(to: fileURL, atomically: true, encoding: .utf8)
    try writeGenerationProvenance(plan: exportedTest, sourcePath: options.planPath, generatedFile: fileURL)
    return CLIResult(output: "Wrote \(fileURL.path)", exitCode: 0)
}
