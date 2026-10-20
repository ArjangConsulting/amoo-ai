import AmooCore
import Foundation
import MCPServer
import SessionCompiler
import StudioProtocol
import TestSession

/// `amoo generate plan` — recompile a recorded session's `report.json`, or compile a hand-authored
/// `*.amoo.json` flow, into a `plan.json` (and `flow.json`) without going back through
/// `amoo mcp serve`.
///
/// This is the offline replay path for a recorded scenario: the same deterministic
/// `SessionPlanCompiler` the MCP `compile_session_to_plan` tool runs, so control-plane calls are
/// dropped, element-scoped gestures keep their row identity, and identically-labelled elements get
/// role-distinguished names. Feed the result straight to `amoo generate test --plan`.
func renderGeneratePlanHelp() -> String {
    """
    Usage: amoo generate plan (--report <path-to-report.json> | --from-flow <path.amoo.json>)
                              [--out <directory>]
                              [--context <amoo.md|test-context.json>]
                              [--test-name <name>] [--test-description <text>]

      Compiles a session into plan.json / flow.json using the same compiler as the MCP
      `compile_session_to_plan` tool. Prints the plan JSON to stdout when --out is omitted.
      The MCP `end_session` tool already writes plan.json on close; this is the offline path for
      re-running that compile against a saved report.json, or for authoring a plan by hand with
      no recorded session at all.

      --report            Path to the recorded session report.json.
      --from-flow         Path to a hand-written flow (the same *.amoo.json `amoo flow` runs) to
                          compile as if it had been recorded. Steps are {"tool", "arguments"} pairs
                          such as tap_element / set_text / assert_visible; a device_launch_app step
                          supplies the app id, launch arguments and environment instead of becoming
                          a test step. ${ENV} values are kept verbatim, not read from the
                          environment — put fixture values in the flow, or bind a helper through
                          --context. Give exactly one of --report and --from-flow.
      --out               Directory to write plan.json and flow.json into.
      --context           App-owned JSON or Markdown profile with a fenced amoo-context JSON block
                          to fold into testContext. Prose-only Markdown is invalid.
      --test-name         Descriptive test name. Falls back to the recorded name, then a
                          semantic name inferred from the flow.
      --test-description  One-line description for the generated test.

    Example (author a plan with no recording, then emit the test):
      amoo generate plan --from-flow Examples/sign-in.amoo.json --test-name SignIn --out out/
      amoo generate test --plan out/plan.json --out Tests/
    """
}

struct GeneratePlanOptions: Equatable {
    /// Exactly one of `reportPath` and `flowPath` is set.
    var reportPath: String?
    var flowPath: String?
    var outputDirectory: String?
    var contextPath: String?
    var testName: String?
    var testDescription: String?
}

enum GeneratePlanParseError: Error, CustomStringConvertible {
    case usage
    case missingValue(flag: String)
    case unexpectedArgument(String)
    case conflictingInputs

    var description: String {
        switch self {
        case .usage: renderGeneratePlanHelp()
        case let .missingValue(flag): "Missing value for \(flag)."
        case let .unexpectedArgument(arg): "Unexpected argument '\(arg)'."
        case .conflictingInputs: "Pass exactly one of --report and --from-flow."
        }
    }
}

// One linear flag-parsing switch; the branch count is inherent, not accidental complexity.
// swiftlint:disable:next cyclomatic_complexity
func parseGeneratePlanOptions(args: [String]) throws -> GeneratePlanOptions {
    guard !args.isEmpty else { throw GeneratePlanParseError.usage }
    var reportPath: String?
    var flowPath: String?
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
        case "--from-flow": flowPath = value
        case "--out": outputDirectory = value
        case "--context": contextPath = value
        case "--test-name": testName = value
        case "--test-description": testDescription = value
        default: throw GeneratePlanParseError.unexpectedArgument(flag)
        }
        index += 2
    }
    if reportPath != nil, flowPath != nil {
        throw GeneratePlanParseError.conflictingInputs
    }
    guard reportPath != nil || flowPath != nil else { throw GeneratePlanParseError.missingValue(flag: "--report") }
    return GeneratePlanOptions(
        reportPath: reportPath,
        flowPath: flowPath,
        outputDirectory: outputDirectory,
        contextPath: contextPath,
        testName: testName,
        testDescription: testDescription
    )
}

/// Turns a hand-written flow into the session report a recording of it would have produced, so the
/// one deterministic compiler serves both. A `device_launch_app` step becomes the report's app id and
/// launch configuration (a recording keeps those on the report, not as a step); every other step is
/// an action. Steps are spaced apart so the compiler's retry-collapse never merges two deliberate,
/// identical taps.
func sessionReport(fromFlow flow: TestFlow, name: String) -> SessionReport {
    var appID = ""
    var launchArguments: [String] = []
    var launchEnvironment: [String: String] = [:]
    var actions: [SessionAction] = []
    let start = Date(timeIntervalSince1970: 0)
    for step in flow.steps {
        if step.tool == "device_launch_app" || step.tool == "start_session" {
            appID = step.arguments["app_id"] ?? appID
            launchArguments = step.arguments["launch_args"]
                .map { $0.split(separator: ",").map(String.init) } ?? launchArguments
            launchEnvironment = step.arguments["environment"]
                .map { DriverToolExecutor.parseEnvironment($0) } ?? launchEnvironment
            continue
        }
        // Flow-only steps lower to what a recording would hold: waiting for an element is an
        // assertion, and pauses, idle waits and screenshots reproduce nothing in a test.
        guard let (tool, arguments) = flowStepForPlan(step) else { continue }
        actions.append(SessionAction(
            timestamp: start.addingTimeInterval(Double(actions.count) * flowStepSpacingSeconds),
            toolName: tool,
            arguments: arguments,
            result: "authored in \(name)",
            isError: false,
            intent: flowIntent(forTool: tool)
        ))
    }
    return SessionReport(
        sessionID: name,
        appID: appID,
        deviceID: flow.deviceID ?? "booted",
        platform: flow.platform.lowercased(),
        startedAt: start,
        endedAt: start.addingTimeInterval(Double(actions.count) * flowStepSpacingSeconds),
        durationSeconds: Double(actions.count) * flowStepSpacingSeconds,
        actionCount: actions.count,
        errorCount: 0,
        isActive: false,
        actions: actions,
        launchArguments: launchArguments,
        launchEnvironment: launchEnvironment
    )
}

/// The tool and arguments a flow step contributes to a plan, or `nil` when it contributes nothing.
func flowStepForPlan(_ step: TestFlow.Step) -> (tool: String, arguments: [String: String])? {
    switch step.tool {
    case FlowPseudoTool.wait, FlowPseudoTool.screenshot:
        return nil
    case FlowPseudoTool.waitFor:
        guard step.arguments["idle"] == nil else { return nil }
        return ("assert_visible", step.arguments)
    default:
        return (step.tool, step.arguments)
    }
}

/// Longer than the compiler's retry-tap window, so repeated identical steps stay separate.
private let flowStepSpacingSeconds = 5.0

/// Mirrors how the recorder classifies a live call: queries are diagnostics, `assert_*` are
/// assertions, everything else is a step to reproduce.
private func flowIntent(forTool tool: String) -> SessionAction.Intent {
    if tool.hasPrefix("assert_") {
        return .assertion
    }
    let queries: Set = [
        "find_elements", "get_view_hierarchy", "get_screen_context", "describe_screen",
        "take_screenshot", "current_app", "list_devices", "list_apps"
    ]
    return queries.contains(tool) ? .diagnostic : .testStep
}

func runGeneratePlanCommand(options: GeneratePlanOptions) throws -> CLIResult {
    let report: SessionReport
    if let flowPath = options.flowPath {
        let flowURL = URL(fileURLWithPath: (flowPath as NSString).expandingTildeInPath)
        let flow = try JSONDecoder().decode(TestFlow.self, from: Data(contentsOf: flowURL))
        guard !flow.steps.isEmpty else {
            return CLIResult(output: "Flow has no steps: \(flowURL.path)", exitCode: 64)
        }
        guard Platform(rawValue: flow.platform.lowercased()) != nil else {
            return CLIResult(output: "Unknown flow platform '\(flow.platform)'.", exitCode: 64)
        }
        report = sessionReport(fromFlow: flow, name: flowURL.deletingPathExtension().lastPathComponent)
    } else if let reportPath = options.reportPath {
        let reportURL = URL(fileURLWithPath: (reportPath as NSString).expandingTildeInPath)
        report = try SessionReport.makeJSONDecoder().decode(
            SessionReport.self,
            from: Data(contentsOf: reportURL)
        )
    } else {
        throw GeneratePlanParseError.missingValue(flag: "--report")
    }

    var result = try SessionPlanCompiler.compile(
        report: report,
        testName: options.testName,
        testDescription: options.testDescription
    )
    let context = try options.contextPath.map {
        try RepositoryTestProfile.load(
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath),
            platform: result.studioTest.platform
        )
    } ?? RepositoryTestProfile.discover(platform: result.studioTest.platform)
    if let context {
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
