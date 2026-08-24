import Foundation
import StudioProtocol
import TestCodeGenerator

public enum GenerateCommandParseError: Error, CustomStringConvertible {
    case usage
    case missingValue(flag: String)
    case unexpectedArgument(String)

    public var description: String {
        switch self {
        case .usage:
            renderGenerateHelp()
        case let .missingValue(flag):
            "Missing value for \(flag)."
        case let .unexpectedArgument(arg):
            "Unexpected argument '\(arg)'."
        }
    }
}

func renderGenerateHelp() -> String {
    "Usage: amoo generate test --plan <path-to-authored-test.json> [--out <directory>]"
}

public struct GenerateTestOptions: Sendable, Equatable {
    public var planPath: String
    public var outputDirectory: String?

    public init(planPath: String, outputDirectory: String?) {
        self.planPath = planPath
        self.outputDirectory = outputDirectory
    }
}

public func parseGenerateTestOptions(args: [String]) throws -> GenerateTestOptions {
    guard !args.isEmpty else { throw GenerateCommandParseError.usage }

    var planPath: String?
    var outputDirectory: String?
    var index = 0

    while index < args.count {
        let flag = args[index]
        guard flag.hasPrefix("--") else { throw GenerateCommandParseError.unexpectedArgument(flag) }
        let valueIndex = index + 1
        guard valueIndex < args.count else { throw GenerateCommandParseError.missingValue(flag: flag) }
        let value = args[valueIndex]
        switch flag {
        case "--plan": planPath = value
        case "--out": outputDirectory = value
        default: throw GenerateCommandParseError.unexpectedArgument(flag)
        }
        index += 2
    }

    guard let planPath else { throw GenerateCommandParseError.missingValue(flag: "--plan") }
    return GenerateTestOptions(planPath: planPath, outputDirectory: outputDirectory)
}

public func runGenerateTestCommand(
    options: GenerateTestOptions,
    emitters: StudioCodeEmitters
) throws -> CLIResult {
    let data = try Data(contentsOf: URL(fileURLWithPath: options.planPath))
    let test = try JSONDecoder().decode(StudioAuthoredTest.self, from: data)
    let platform = test.platform.lowercased()
    let emitter: (any StudioCodeEmitting)? = if platform.contains("android") {
        emitters.android
    } else if platform.contains("ios") {
        emitters.ios
    } else {
        nil
    }
    guard let emitter else {
        return CLIResult(output: "No code generator available for platform '\(test.platform)'.", exitCode: 64)
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
