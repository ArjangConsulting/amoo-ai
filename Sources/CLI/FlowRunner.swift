import AmooCore
import AmooTools
import Foundation
import StudioProtocol

// MARK: - Step execution

/// Steps only `amoo flow` understands. Each lowers to a real MCP tool (or to local work) so a flow can
/// wait and capture evidence without a shell loop around `amoo device`.
enum FlowPseudoTool {
    /// `wait` — sleep `duration_ms` (or `seconds`).
    static let wait = "wait"
    /// `wait_for` — an element (`id`/`label`/`contains_text`, up to `timeout_ms`) or `idle=true`.
    static let waitFor = "wait_for"
    /// `screenshot` — saved as `<output-dir>/NN-<name>.png`, numbered by step.
    static let screenshot = "screenshot"

    static let all: Set = [wait, waitFor, screenshot]
}

/// Where a flow run reads variables from and writes screenshots to.
struct FlowRunContext: Sendable {
    /// Built-ins first, then the flow's `vars`, then `--var` overrides, then the environment.
    var variables: [String: String]
    var environment: [String: String]
    var outputDirectory: URL?
    var continueOnError: Bool
    /// The project's `screenshots` defaults, from the `amoo.config.json` above the flow file.
    var screenshotPolicy = ScreenshotPolicy.standard
    /// Time source for waits, injectable so tests do not sleep.
    var sleep: @Sendable (Swift.Duration) async -> Void = { try? await Task.sleep(for: $0) }

    init(
        variables: [String: String] = [:],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        outputDirectory: URL? = nil,
        continueOnError: Bool = false
    ) {
        self.variables = variables
        self.environment = environment
        self.outputDirectory = outputDirectory
        self.continueOnError = continueOnError
    }
}

/// One step's result, as `report.json` records it.
struct FlowStepRecord: Encodable, Equatable {
    var number: Int
    var name: String
    var tool: String
    /// 1-based, for a step with `repeat`.
    var repetition: Int?
    /// `passed`, `failed` or `optional_failed`.
    var status: String
    var elapsedMilliseconds: Int
    var message: String
    /// The tool's structured result: for a failed assertion, its `failure_kind` and last observed state.
    var result: Value?

    enum CodingKeys: String, CodingKey {
        case number, name, tool, repetition, status, message, result
        case elapsedMilliseconds = "elapsed_ms"
    }
}

/// The outcome of every step a flow ran.
struct FlowRunResult: Equatable {
    var lines: [String] = []
    var steps: [FlowStepRecord] = []
    var passed = 0
    var failed = 0
    /// Optional steps that failed: reported, but not failures of the run.
    var optionalFailed = 0
    /// Whether the run ended early on a failed step with `on_error: stop`.
    var stopped = false
    /// Videos saved by `--record-video` or a `start_recording` step left running at the end.
    var recordings: [String] = []

    var succeeded: Bool {
        failed == 0
    }
}

/// Replaces each `${name}` in `value`, looking in `variables` and then the environment. A name found
/// in neither is an error, so a typo does not silently type the literal text `${name}`.
func interpolateFlowVariables(
    in value: String,
    variables: [String: String],
    environment: [String: String]
) throws -> String {
    var output = ""
    var rest = Substring(value)
    while let open = rest.range(of: "${") {
        output += rest[..<open.lowerBound]
        guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
            output += rest[open.lowerBound...]
            return output
        }
        let name = String(rest[open.upperBound ..< close])
        guard let resolved = variables[name] ?? environment[name] else {
            throw AmooError.commandFailed(command: "flow", output: "Missing variable or environment value: \(name)")
        }
        output += resolved
        rest = rest[rest.index(after: close)...]
    }
    output += rest
    return output
}

/// Runs `flow.steps` against `executor`, honouring `on_error`, `repeat`, variables and the
/// flow-only steps in ``FlowPseudoTool``.
func runFlowSteps(
    _ flow: TestFlow,
    executor: any ToolExecutor,
    context: FlowRunContext
) async -> FlowRunResult {
    var result = FlowRunResult()
    for (index, original) in flow.steps.enumerated() {
        let step = withoutRedundantEffectCheck(original, next: flow.steps.dropFirst(index + 1).first)
        let label = step.name ?? step.tool
        let policy = context.continueOnError ? .continue : step.onError ?? flow.onError
        for repetition in 0 ..< max(1, step.repeatCount ?? 1) {
            let suffix = (step.repeatCount ?? 1) > 1 ? " [\(repetition + 1)/\(step.repeatCount ?? 1)]" : ""
            let started = ContinuousClock.now
            let outcome = await failingUnmetExpectation(
                runFlowStep(step, number: index + 1, executor: executor, context: context)
            )
            result.steps.append(FlowStepRecord(
                number: index + 1,
                name: label,
                tool: step.tool,
                repetition: (step.repeatCount ?? 1) > 1 ? repetition + 1 : nil,
                status: !outcome.isError ? "passed" : step.optional ? "optional_failed" : "failed",
                elapsedMilliseconds: milliseconds(since: started),
                message: outcome.content,
                result: outcome.structuredContent
            ))
            if outcome.isError, step.optional {
                result.optionalFailed += 1
                result.lines.append("– \(index + 1). \(label)\(suffix) (optional): \(outcome.content)")
            } else if outcome.isError {
                result.failed += 1
                result.lines.append("✗ \(index + 1). \(label)\(suffix): \(outcome.content)")
                if policy == .stop {
                    result.stopped = true
                    return result
                }
            } else {
                result.passed += 1
                result.lines.append("✓ \(index + 1). \(label)\(suffix): \(outcome.content)")
            }
        }
    }
    return result
}

/// `outcome` as a failure when the flow could not verify the tap's postcondition.
///
/// `tap_element` reports an unmet expectation without failing, because the tap was dispatched and a
/// caller that retried an error could tap a toggle back. A flow has no such caller: the expectation
/// is its postcondition, and passing the step let a flow go on to fail one step later with a
/// misleading "no element matched".
func failingUnmetExpectation(_ outcome: ToolResult) -> ToolResult {
    guard !outcome.isError, var fields = outcome.structuredContent?.objectValue else { return outcome }
    let failureKind: String
    if fields["expected_effect_met"] == .bool(false) {
        failureKind = "expectation_not_met"
    } else if fields["expectation_status"] == .string("unverified") {
        failureKind = "expectation_unverified"
    } else {
        return outcome
    }
    fields["failure_kind"] = .string(failureKind)
    return ToolResult(content: outcome.content, isError: true, structuredContent: .object(fields))
}

/// `step` with `check_effect: false` when it is a `tap_element` that leaves the choice open and the
/// next step verifies the outcome itself (an assertion, `wait_for`, or a `scroll_to_element` that fails
/// when the tap did not open its screen). The tap's own effect check
/// re-reads the hierarchy until the screen changes, about half a second per tap, only to report what
/// that next step proves anyway. The check that the tap would not land on something covering the
/// target still runs.
func withoutRedundantEffectCheck(_ step: TestFlow.Step, next: TestFlow.Step?) -> TestFlow.Step {
    guard step.tool == "tap_element", step.arguments["check_effect"] == nil,
          step.arguments["effect_timeout_ms"] == nil, let next,
          next.tool.hasPrefix("assert_") || next.tool == "scroll_to_element"
          || (next.tool == FlowPseudoTool.waitFor && next.arguments["idle"] == nil)
    else { return step }
    var lighter = step
    lighter.arguments["check_effect"] = "false"
    return lighter
}

private func runFlowStep(
    _ step: TestFlow.Step,
    number: Int,
    executor: any ToolExecutor,
    context: FlowRunContext
) async -> ToolResult {
    let arguments: [String: String]
    do {
        arguments = try step.arguments.mapValues {
            try interpolateFlowVariables(in: $0, variables: context.variables, environment: context.environment)
        }
    } catch {
        return .error("\(error)")
    }
    switch step.tool {
    case FlowPseudoTool.wait:
        return await runFlowWait(arguments, context: context)
    case FlowPseudoTool.waitFor:
        return await runFlowWaitFor(arguments, executor: executor, context: context)
    case FlowPseudoTool.screenshot:
        return await runFlowScreenshot(arguments, name: step.name, number: number, executor: executor, context: context)
    default:
        return await executor.execute(toolName: step.tool, arguments: arguments)
    }
}

private func runFlowWait(_ arguments: [String: String], context: FlowRunContext) async -> ToolResult {
    let milliseconds = arguments["duration_ms"].flatMap(Int.init)
        ?? arguments["seconds"].flatMap(Double.init).flatMap { Int(exactly: ($0 * 1000).rounded(.towardZero)) }
    guard let milliseconds, (0 ... 600_000).contains(milliseconds) else {
        return .error("wait needs duration_ms (0-600000) or seconds.")
    }
    await context.sleep(.milliseconds(milliseconds))
    return .success("Waited \(milliseconds)ms")
}

private func runFlowWaitFor(
    _ arguments: [String: String],
    executor: any ToolExecutor,
    context: FlowRunContext
) async -> ToolResult {
    let timeoutMS = arguments["timeout_ms"].flatMap(Int.init) ?? 10000
    if boolFlowArgument(arguments["idle"]) == true {
        let stableMS = arguments["stable_ms"].flatMap(Int.init) ?? 500
        return await waitForIdleScreen(timeoutMS: timeoutMS, stableMS: stableMS, executor: executor, context: context)
    }
    guard arguments["id"] != nil || arguments["label"] != nil || arguments["contains_text"] != nil else {
        return .error("wait_for needs id, label or contains_text, or idle=true.")
    }
    return await executor.execute(toolName: "assert_visible", arguments: flowWaitAssertionArguments(arguments))
}

func flowWaitAssertionArguments(_ arguments: [String: String]) -> [String: String] {
    var forwarded = arguments
    forwarded["idle"] = nil
    forwarded["stable_ms"] = nil
    forwarded["timeout_ms"] = String(arguments["timeout_ms"].flatMap(Int.init) ?? 10000)
    return forwarded
}

/// Polls the screen summary until it stops changing for `stableMS`, so a screenshot is not taken
/// mid-transition or before the first frame renders.
private func waitForIdleScreen(
    timeoutMS: Int,
    stableMS: Int,
    executor: any ToolExecutor,
    context: FlowRunContext
) async -> ToolResult {
    let interval = 250
    var elapsed = 0
    var stableFor = 0
    var previous: String?
    while elapsed <= timeoutMS {
        let current = await executor.execute(toolName: "get_screen_context", arguments: [:])
        if current.isError {
            return current
        }
        stableFor = current.content == previous ? stableFor + interval : 0
        if stableFor >= stableMS {
            return .success("Screen idle for \(stableMS)ms")
        }
        previous = current.content
        await context.sleep(.milliseconds(interval))
        elapsed += interval
    }
    return .error("Screen was still changing after \(timeoutMS)ms.")
}

private func runFlowScreenshot(
    _ arguments: [String: String],
    name: String?,
    number: Int,
    executor: any ToolExecutor,
    context: FlowRunContext
) async -> ToolResult {
    guard let directory = context.outputDirectory else {
        return .error("screenshot needs an output directory: pass --output-dir.")
    }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        return .error("Cannot create \(directory.path): \(error)")
    }
    let stem = flowFileStem(arguments["name"] ?? name ?? "screen")
    let file = directory.appending(path: String(format: "%02d-%@.png", number, stem))
    var forwarded = arguments.filter { $0.key != "name" }
    forwarded["output"] = file.path
    forwarded["return_image"] = "false"
    // Flow captures are checked-in evidence and `shots diff` baselines, so they keep native pixels
    // unless the step sets its own scale or the project set `screenshots.scale`, which then sizes
    // them like every other capture. A full-resolution capture an agent then views costs it full
    // image tokens.
    if forwarded["scale"] == nil, context.screenshotPolicy.scale == 1 {
        forwarded["scale"] = "1"
    }
    let result = await executor.execute(toolName: "take_screenshot", arguments: forwarded)
    return result.isError ? result : .success("Saved \(file.path)")
}

/// Letters, digits and dashes only, so a step name always makes a safe file name.
func flowFileStem(_ raw: String) -> String {
    let cleaned = raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    let collapsed = String(cleaned).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    return collapsed.isEmpty ? "screen" : String(collapsed.prefix(60))
}

func boolFlowArgument(_ raw: String?) -> Bool? {
    switch raw?.lowercased() {
    case "true", "1", "yes": true
    case "false", "0", "no": false
    default: nil
    }
}
