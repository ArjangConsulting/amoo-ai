import AmooCore
import Foundation
import StudioProtocol
import TestSession

/// A step recorded in a `.amoo.json` flow file, runnable via `amoo flow` with no translation.
/// Mirrors `TestFlow.Step` in `Sources/CLI/FlowCommand.swift` — kept separate (rather than
/// shared) because `TestFlow` lives in the `CLI` executable target, which `MCPServer` cannot
/// depend on. Field names/order match exactly so a `CompiledSessionFlow` round-trips through
/// the same JSON shape `amoo flow` expects.
public struct CompiledSessionFlow: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public let name: String?
        public let tool: String
        public let arguments: [String: String]

        public init(name: String? = nil, tool: String, arguments: [String: String]) {
            self.name = name
            self.tool = tool
            self.arguments = arguments
        }
    }

    public let platform: String
    public let deviceID: String
    public let steps: [Step]

    enum CodingKeys: String, CodingKey {
        case platform
        case deviceID = "device_id"
        case steps
    }

    public init(platform: String, deviceID: String, steps: [Step]) {
        self.platform = platform
        self.deviceID = deviceID
        self.steps = steps
    }
}

/// One action excluded from `compiledPlan.toolOperations`, or included with an approximate
/// translation, surfaced so the caller knows what to review before generating code.
///
/// Aliased to the `StudioProtocol` type so there is exactly one warning shape in the system: the
/// same values returned here are also persisted inside `StudioCompiledPlan.warnings`, which is what
/// lets `amoo generate test` detect dropped steps in a plan it reads back off disk.
public typealias SessionPlanWarning = StudioPlanWarning

public enum SessionPlanCompilerError: Error, Equatable, CustomStringConvertible {
    case unsupportedPlatform(String)

    public var description: String {
        switch self {
        case let .unsupportedPlatform(value):
            "Session records an unsupported platform '\(value)'; expected iOS or Android."
        }
    }
}

public struct CompileSessionToPlanResult: Codable, Sendable {
    public let testFlow: CompiledSessionFlow
    public let studioTest: StudioAuthoredTest
    public let warnings: [SessionPlanWarning]
    /// Every run of two or more consecutive identical taps, collapsed or not, with the gaps that
    /// decided it. This is the evidence for tuning `retryTapInterval` — the default is a guess, and
    /// the runs it *declines* to collapse are as informative as the ones it does.
    public let retryRunObservations: [SessionPlanCompiler.RetryRunObservation]
    /// The interval this compile actually used, so a report is interpretable on its own.
    public let retryTapIntervalSeconds: Double

    public init(
        testFlow: CompiledSessionFlow,
        studioTest: StudioAuthoredTest,
        warnings: [SessionPlanWarning],
        retryRunObservations: [SessionPlanCompiler.RetryRunObservation] = [],
        retryTapIntervalSeconds: Double = SessionPlanCompiler.defaultRetryTapInterval
    ) {
        self.testFlow = testFlow
        self.studioTest = studioTest
        self.warnings = warnings
        self.retryRunObservations = retryRunObservations
        self.retryTapIntervalSeconds = retryTapIntervalSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case testFlow, studioTest, warnings, retryRunObservations, retryTapIntervalSeconds
    }

    /// Both new fields post-date plans already written to disk, so absence decodes to the
    /// pre-existing behaviour rather than failing to read an older artifact.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        testFlow = try container.decode(CompiledSessionFlow.self, forKey: .testFlow)
        studioTest = try container.decode(StudioAuthoredTest.self, forKey: .studioTest)
        warnings = try container.decodeIfPresent([SessionPlanWarning].self, forKey: .warnings) ?? []
        retryRunObservations = try container.decodeIfPresent(
            [SessionPlanCompiler.RetryRunObservation].self,
            forKey: .retryRunObservations
        ) ?? []
        retryTapIntervalSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .retryTapIntervalSeconds
        ) ?? SessionPlanCompiler.defaultRetryTapInterval
    }
}

// Compiler pipeline helpers are split across extensions.
// swiftlint:disable type_body_length
/// Deterministically translates a recorded `SessionReport` into both a directly-replayable
/// `CompiledSessionFlow` (for `amoo flow`) and a best-effort `StudioAuthoredTest` (for
/// `amoo generate test --plan`). No LLM involved — this mirrors the mechanical nature of a
/// recording, as opposed to `StudioChatService`'s conversational plan authoring.
public enum SessionPlanCompiler {
    struct TranslatedAction {
        let studioTool: StudioTool
        let studioArguments: [String: String]
        let approximate: Bool
    }

    /// MCP tool names that map 1:1 onto a Studio tool with no argument remapping needed.
    ///
    /// `scroll` is listed separately from `swipe_in_direction` on purpose, even though its
    /// `direction`/`distance` arguments look like a subset of the latter's. The two have *inverted*
    /// direction semantics: `scroll` names the direction the content moves (the companions
    /// implement `scroll(.down)` as a swipe-*up* gesture — see `XCUITestBridge.scroll` and
    /// `UIAutomatorBridge.scroll`), while `swipe_in_direction` names the raw finger direction.
    /// Collapsing them into one tool would silently reverse every recorded scroll.
    private static let directTranslations: Set<StudioTool> = [
        .tapElement, .setText, .typeText, .swipeInDirection, .scroll, .takeScreenshot, .pressBack
    ]

    /// amoo's own session / codegen lifecycle tools. They never touch the app under test, so they
    /// must never surface as a step — not even as an `XCTFail` placeholder — in a generated test.
    ///
    /// Legacy recordings may still contain these calls; ignore them instead of emitting failing test steps.
    static let controlPlaneTools: Set<String> = [
        "start_session", "start_test_session", "end_session", "end_test_session",
        "list_sessions", "get_session_report", "compile_session_to_plan", "run_steps"
    ]

    /// Tools that inspect the app without changing it. They have no place in generated test code,
    /// so their absence from `toolOperations` is intended rather than a gap in the vocabulary —
    /// recorded as `.notApplicable` so it reads as a deliberate decision, not a silent drop.
    private static let queryOnlyTools: Set<String> = [
        "find_elements", "get_view_hierarchy", "get_screen_context", "describe_screen",
        "is_keyboard_visible", "current_app", "list_devices", "list_apps", "list_sessions",
        "get_session_report", "take_screenshot_metadata", "find_element_by_description",
        "suggest_test_actions", "analyze_ai_testability", "highlight_a11y_issues",
        "audit_app", "audit_accessibility", "audit_security"
    ]

    /// MCP tool names that map onto Studio's codegen-facing tool vocabulary, and how their
    /// arguments translate. Anything not listed here has no Studio-tool equivalent and is
    /// excluded from `compiledPlan.toolOperations` (but still included, untranslated, in the
    /// replayable `testFlow`).
    private static func translate(toolName: String, arguments: [String: String]) -> TranslatedAction? {
        if let tool = StudioTool(rawValue: toolName), directTranslations.contains(tool) {
            return TranslatedAction(studioTool: tool, studioArguments: arguments, approximate: false)
        }
        switch toolName {
        case "fill_field":
            return translateFillField(arguments)
        case "assert_visible":
            return translateAssertVisible(arguments)
        case "assert_absent":
            return translateAssertAbsent(arguments)
        case "assert_value":
            return translateAssertValue(arguments)
        case "assert_enabled":
            return translateAssertEnabled(arguments)
        default:
            return nil
        }
    }

    private struct ProcessedAction {
        let operation: StudioToolOperation?
        let step: StudioAuthoredTest.Step?
        let warnings: [SessionPlanWarning]
    }

    // Keeps the ordered action-classification and warning pipeline visible in one place.
    // swiftlint:disable:next function_body_length
    private static func process(
        index: Int,
        action: SessionAction,
        next: SessionAction?,
        retry: RetryContext
    ) -> ProcessedAction {
        let transient = looksTransient(action)

        // amoo's own lifecycle calls are never an application test step. Drop them before any
        // vocabulary check so a recorded `compile_session_to_plan` (from an `end_session` recompile
        // or an explicit call) becomes a `.notApplicable` note, never an `.excluded` gap.
        if controlPlaneTools.contains(action.toolName) {
            return ProcessedAction(
                operation: nil,
                step: nil,
                warnings: [SessionPlanWarning(
                    kind: .notApplicable,
                    actionIndex: index,
                    toolName: action.toolName,
                    reason: "amoo session/codegen control-plane call; never part of the generated test"
                )]
            )
        }

        // A failed selector is evidence from exploration, never a replayable test instruction.
        // Check isError as well as intent so plans compiled from recordings made before intent was
        // introduced receive the same safety guarantee.
        if action.isError || action.intent == .failedProbe {
            return ProcessedAction(
                operation: nil,
                step: nil,
                warnings: [SessionPlanWarning(
                    kind: .notApplicable,
                    actionIndex: index,
                    toolName: action.toolName,
                    reason: "failed exploratory action omitted from compiledPlan: \(action.result)",
                    transient: transient
                )]
            )
        }
        if action.intent == .diagnostic, queryOnlyTools.contains(action.toolName) {
            return processInspection(index: index, action: action, next: next, transient: transient)
        }
        if action.intent == .diagnostic || action.intent == .recovery {
            return ProcessedAction(
                operation: nil,
                step: nil,
                warnings: [SessionPlanWarning(
                    kind: .notApplicable,
                    actionIndex: index,
                    toolName: action.toolName,
                    reason: "\(action.intent.rawValue) action intentionally omitted from compiledPlan",
                    transient: transient
                )]
            )
        }

        guard let translated = translate(toolName: action.toolName, arguments: action.arguments) else {
            if queryOnlyTools.contains(action.toolName) {
                return processInspection(index: index, action: action, next: next, transient: transient)
            }
            let warning = SessionPlanWarning(
                kind: .excluded,
                actionIndex: index,
                toolName: action.toolName,
                reason: excludedReason(for: action),
                transient: transient
            )
            return ProcessedAction(operation: nil, step: nil, warnings: [warning])
        }

        var warnings: [SessionPlanWarning] = []
        if translated.approximate {
            warnings.append(SessionPlanWarning(
                kind: .approximate,
                actionIndex: index,
                toolName: action.toolName,
                reason: "translated to '\(translated.studioTool.rawValue)' using an approximate selector mapping;"
                    + " review before generating"
            ))
        }
        if translated.studioArguments.values.contains(where: { $0.contains("<redacted") }) {
            warnings.append(SessionPlanWarning(
                kind: .redacted,
                actionIndex: index,
                toolName: action.toolName,
                reason: "contains a redacted value that must be hand-filled before replay or codegen"
            ))
        }
        if transient {
            warnings.append(transientWarning(index: index, toolName: action.toolName))
        }
        if retry.count > 1 {
            warnings.append(retryWarning(
                index: index,
                toolName: action.toolName,
                retryCount: retry.count,
                interval: retry.interval,
                gaps: retry.gaps
            ))
        }

        let stepID = "step-\(index)"
        let operation = StudioToolOperation(
            id: stepID,
            // Back to a String at the boundary: the plan's wire format is unchanged.
            tool: translated.studioTool.rawValue,
            arguments: translated.studioArguments
        )
        let described = describe(tool: translated.studioTool, arguments: translated.studioArguments)
        let step = StudioAuthoredTest.Step(id: stepID, instruction: described.instruction, expected: described.expected)
        return ProcessedAction(operation: operation, step: step, warnings: warnings)
    }

    /// A `describe_screen` / `find_elements` / `get_view_hierarchy` right before a state change
    /// usually encodes "I verified X was on screen". Compile the last such inspection into an
    /// `assert_visible` for the element it queried; if it queried nothing assertable, keep it out
    /// of the plan but point out that an assertion belongs there.
    private static func processInspection(
        index: Int,
        action: SessionAction,
        next: SessionAction?,
        transient: Bool
    ) -> ProcessedAction {
        let precedesTransition = next.map(isTransition) ?? false
        let isSuccessfulTrailingAssertion = next == nil && action.toolName == "find_elements"
            && action.result.contains("Found 0 element(s)") == false
        guard precedesTransition || isSuccessfulTrailingAssertion, let selector = inspectionSelector(action) else {
            let reason = precedesTransition
                ? "inspection right before a state change, but it queried nothing assertable; "
                + "consider adding an explicit assertion here"
                : "inspection-only tool with no effect on the app; intentionally omitted from compiledPlan"
            return ProcessedAction(
                operation: nil,
                step: nil,
                warnings: [SessionPlanWarning(
                    kind: .notApplicable,
                    actionIndex: index,
                    toolName: action.toolName,
                    reason: reason,
                    transient: transient
                )]
            )
        }
        let stepID = "step-\(index)"
        let operation = StudioToolOperation(
            id: stepID,
            tool: StudioTool.assertVisible.rawValue,
            arguments: selector
        )
        let described = describe(tool: .assertVisible, arguments: selector)
        let step = StudioAuthoredTest.Step(id: stepID, instruction: described.instruction, expected: described.expected)
        let warning = SessionPlanWarning(
            kind: .approximate,
            actionIndex: index,
            toolName: action.toolName,
            reason: "compiled a pre-transition inspection into assert_visible on its queried element; "
                + "confirm this is the check the recording meant to make",
            transient: transient
        )
        return ProcessedAction(operation: operation, step: step, warnings: [warning])
    }

    /// Throws when the recorded session names a platform that is neither iOS nor Android. A session
    /// is written by our own recorder, so that means a corrupt or hand-edited report — guessing a
    /// platform there would generate a test for the wrong OS.
    /// Runs `process` over the actions the retry pass kept, giving each one its retry context.
    ///
    /// `next` deliberately skips suppressed actions: the pre-transition inspection heuristic asks
    /// "what happens after this?", and a suppressed duplicate tap is not a distinct next step.
    private static func processActions(
        _ actions: [SessionAction],
        retries: RetryAnalysis,
        interval: TimeInterval
    ) -> [ProcessedAction] {
        let gapsByIndex = Dictionary(
            uniqueKeysWithValues: retries.observations.map { ($0.actionIndex, $0.gaps) }
        )
        func nextAction(after offset: Int) -> SessionAction? {
            var cursor = offset + 1
            while cursor < actions.count {
                if !retries.suppressed.contains(cursor) {
                    return actions[cursor]
                }
                cursor += 1
            }
            return nil
        }

        var processed: [ProcessedAction] = []
        var recentElements: [RecordedElement] = []
        processed.reserveCapacity(actions.count)
        for (offset, action) in actions.enumerated() where !retries.suppressed.contains(offset) {
            if action.observedElements.isEmpty == false {
                recentElements = action.observedElements
            } else if action.toolName == "find_elements" {
                recentElements = legacyRecordedElements(from: action.result)
            }
            let effectiveAction = attachObservedLabel(
                attachGestureTargetLabel(
                    semanticCoordinateSwipe(action, recentElements: recentElements),
                    recentElements: recentElements
                ),
                recentElements: recentElements
            )
            processed.append(process(
                index: offset,
                action: effectiveAction,
                next: nextAction(after: offset),
                retry: RetryContext(
                    count: retries.counts[offset] ?? 1,
                    interval: interval,
                    gaps: gapsByIndex[offset] ?? []
                )
            ))
            if invalidatesRecordedGeometry(action.toolName) {
                recentElements = []
            }
        }
        return processed
    }

    // Preserve ordered plan construction and validation.
    // swiftlint:disable function_body_length
    /// - Parameter retryTapInterval: How close together identical taps must be to read as a retry
    ///   loop rather than deliberate repeats. Defaults to `AMOO_RETRY_TAP_INTERVAL_MS`, then
    ///   `defaultRetryTapInterval`. See that property for why this is tunable and not a fixed
    ///   constant — every run of repeated taps reports its gaps in `retryRunObservations` so the
    ///   value can be chosen from real recordings.
    public static func compile(
        report: SessionReport,
        testName: String?,
        testDescription: String?,
        retryTapInterval: TimeInterval? = nil
    ) throws -> CompileSessionToPlanResult {
        let interval = retryTapInterval ?? retryTapIntervalFromEnvironment()
        guard let platform = Platform(lenient: report.platform) else {
            throw SessionPlanCompilerError.unsupportedPlatform(report.platform)
        }
        let flowSteps = report.actions.map {
            CompiledSessionFlow.Step(tool: $0.toolName, arguments: $0.arguments)
        }
        let testFlow = CompiledSessionFlow(
            platform: report.platform,
            deviceID: report.deviceID,
            steps: flowSteps
        )

        let retries = retryRuns(report.actions, interval: interval)
        let processed = processActions(report.actions, retries: retries, interval: interval)
        let toolOperations = annotatePresetOptionTaps(processed.compactMap(\.operation))
        let steps = processed.compactMap(\.step)
        var warnings = processed.flatMap(\.warnings)
        if (report.launchArguments + Array(report.launchEnvironment.values))
            .contains(where: { $0.contains("<redacted") }) {
            warnings.append(SessionPlanWarning(
                kind: .redacted,
                actionIndex: 0,
                toolName: "start_session",
                reason: "Launch metadata contains redacted secrets; bind runtime credentials before exporting."
            ))
        }

        // A recording made through the MCP flow keeps `compile_session_to_plan` out of its history,
        // so its `test_name` / `test_description` would otherwise be lost when `end_session` (or a
        // re-run of `amoo generate plan`) recompiles the report. Recover them from any control-plane
        // call the history still carries, so the descriptive name survives a recompile.
        let recordedName = report.actions.last {
            controlPlaneTools.contains($0.toolName) && ($0.arguments["test_name"]?.isEmpty == false)
        }?.arguments["test_name"]
        let recordedDescription = report.actions.last {
            controlPlaneTools.contains($0.toolName) && ($0.arguments["test_description"]?.isEmpty == false)
        }?.arguments["test_description"]

        let name = testName ?? report.codegenIntent?.testName ?? report
            .testName ?? recordedName ?? semanticTestName(for: report)
        let description = testDescription ?? report.codegenIntent?.testDescription ?? recordedDescription
            ?? "Generated from session \(report.sessionID) (\(report.appID) on \(report.deviceID))"

        var studioTest = StudioAuthoredTest(
            formatVersion: 1,
            name: name,
            description: description,
            platform: platform,
            steps: steps,
            requirements: StudioTestRequirements(
                appId: report.appID,
                deviceName: report.deviceID,
                launchArguments: report.launchArguments,
                launchEnvironment: report.launchEnvironment
            ),
            compiledPlan: StudioCompiledPlan(
                compiler: "session-compiler",
                compilerVersion: "1",
                toolOperations: toolOperations,
                // Persisted into the plan, not just returned alongside it, so a plan saved to disk
                // still knows what went missing when `amoo generate test` reads it back later.
                warnings: warnings.isEmpty ? [] : warnings
            )
        )

        if let json = report.codegenIntent?.contextJSON {
            let context = try JSONDecoder().decode(StudioTestContext.self, from: Data(json.utf8))
            studioTest = studioTest.replacingTestContext(context)
        }
        return CompileSessionToPlanResult(
            testFlow: testFlow,
            studioTest: studioTest,
            warnings: warnings,
            retryRunObservations: retries.observations,
            retryTapIntervalSeconds: interval
        )
    }
}

// swiftlint:enable function_body_length
// swiftlint:enable type_body_length
