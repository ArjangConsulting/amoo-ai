import Foundation
import MCPServer
import StudioProtocol
import TestSession

/// `amoo generate plan` — recompile a recorded session's `report.json` into a fresh
/// `plan.json` (and `flow.json`) without going back through `amoo mcp serve`.
///
/// This is the offline replay path for a recorded scenario: the same deterministic
/// `SessionPlanCompiler` the MCP `compile_session_to_plan` tool runs, so control-plane calls are
/// dropped, element-scoped gestures keep their row identity, and identically-labelled elements get
/// role-distinguished names. Feed the result straight to `amoo generate test --plan`.
func renderGeneratePlanHelp() -> String {
    """
    Usage: amoo generate plan --report <path-to-report.json> [--out <directory>]
                              [--context <path-to-test-context.json>]
                              [--test-name <name>] [--test-description <text>]

      Recompiles a recorded session into plan.json / flow.json using the same compiler as the
      MCP `compile_session_to_plan` tool. Prints the plan JSON to stdout when --out is omitted.
      The MCP `end_session` tool already writes plan.json on close; this is the offline path for
      re-running that compile against a saved report.json.

      --report            Path to the recorded session report.json.
      --out               Directory to write plan.json and flow.json into.
      --context           App-owned test-context JSON to fold into the plan's testContext.
      --test-name         Descriptive test name. Falls back to the recorded name, then a
                          semantic name inferred from the flow.
      --test-description  One-line description for the generated test.
    """
}

struct GeneratePlanOptions: Equatable {
    var reportPath: String
    var outputDirectory: String?
    var contextPath: String?
    var testName: String?
    var testDescription: String?
}

enum GeneratePlanParseError: Error, CustomStringConvertible {
    case usage
    case missingValue(flag: String)
    case unexpectedArgument(String)

    var description: String {
        switch self {
        case .usage: renderGeneratePlanHelp()
        case let .missingValue(flag): "Missing value for \(flag)."
        case let .unexpectedArgument(arg): "Unexpected argument '\(arg)'."
        }
    }
}

// One linear flag-parsing switch; the branch count is inherent, not accidental complexity.
// swiftlint:disable:next cyclomatic_complexity
func parseGeneratePlanOptions(args: [String]) throws -> GeneratePlanOptions {
    guard !args.isEmpty else { throw GeneratePlanParseError.usage }
    var reportPath: String?
    var outputDirectory: String?
    var contextPath: String?
    var testName: String?
    var testDescription: String?
    var index = 0
    while index < args.count {
        let flag = args[index]
        guard flag.hasPrefix("--") else { throw GeneratePlanParseError.unexpectedArgument(flag) }
        let valueIndex = index + 1
        guard valueIndex < args.count else { throw GeneratePlanParseError.missingValue(flag: flag) }
        let value = args[valueIndex]
        switch flag {
        case "--report": reportPath = value
        case "--out": outputDirectory = value
        case "--context": contextPath = value
        case "--test-name": testName = value
        case "--test-description": testDescription = value
        default: throw GeneratePlanParseError.unexpectedArgument(flag)
        }
        index += 2
    }
    guard let reportPath else { throw GeneratePlanParseError.missingValue(flag: "--report") }
    return GeneratePlanOptions(
        reportPath: reportPath,
        outputDirectory: outputDirectory,
        contextPath: contextPath,
        testName: testName,
        testDescription: testDescription
    )
}

func runGeneratePlanCommand(options: GeneratePlanOptions) throws -> CLIResult {
    let reportURL = URL(fileURLWithPath: (options.reportPath as NSString).expandingTildeInPath)
    let report = try SessionReport.makeJSONDecoder().decode(
        SessionReport.self,
        from: Data(contentsOf: reportURL)
    )

    var result = try SessionPlanCompiler.compile(
        report: report,
        testName: options.testName,
        testDescription: options.testDescription
    )
    if let contextPath = options.contextPath {
        let contextURL = URL(fileURLWithPath: (contextPath as NSString).expandingTildeInPath)
        let context = try JSONDecoder().decode(StudioTestContext.self, from: Data(contentsOf: contextURL))
        result = CompileSessionToPlanResult(
            testFlow: result.testFlow,
            studioTest: result.studioTest.replacingTestContext(context),
            warnings: result.warnings,
            retryRunObservations: result.retryRunObservations,
            retryTapIntervalSeconds: result.retryTapIntervalSeconds
        )
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let planData = try encoder.encode(result.studioTest)

    guard let outputDirectory = options.outputDirectory else {
        return CLIResult(output: String(bytes: planData, encoding: .utf8) ?? "", exitCode: 0)
    }
    let directoryURL = URL(fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let planURL = directoryURL.appendingPathComponent("plan.json")
    let flowURL = directoryURL.appendingPathComponent("flow.json")
    try planData.write(to: planURL)
    try encoder.encode(result.testFlow).write(to: flowURL)

    let warningNote = result.warnings.isEmpty ? "" : " (\(result.warnings.count) warning(s))"
    return CLIResult(
        output: "Wrote \(planURL.path) and \(flowURL.path)\(warningNote)",
        exitCode: 0
    )
}
