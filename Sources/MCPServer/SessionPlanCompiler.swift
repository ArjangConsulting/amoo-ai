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

    public init(testFlow: CompiledSessionFlow, studioTest: StudioAuthoredTest, warnings: [SessionPlanWarning]) {
        self.testFlow = testFlow
        self.studioTest = studioTest
        self.warnings = warnings
    }
}

/// Deterministically translates a recorded `SessionReport` into both a directly-replayable
/// `CompiledSessionFlow` (for `amoo flow`) and a best-effort `StudioAuthoredTest` (for
/// `amoo generate test --plan`). No LLM involved — this mirrors the mechanical nature of a
/// recording, as opposed to `StudioChatService`'s conversational plan authoring.
public enum SessionPlanCompiler {
    private struct TranslatedAction {
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

    private static func translateFillField(_ arguments: [String: String]) -> TranslatedAction {
        var mapped = arguments
        mapped["contains_text"] = mapped["contains_text"] ?? mapped["field_description"]
        mapped["field_description"] = nil
        return TranslatedAction(studioTool: .setText, studioArguments: mapped, approximate: true)
    }

    private static func translateAssertVisible(_ arguments: [String: String]) -> TranslatedAction {
        var mapped = arguments
        if mapped["id"] == nil, mapped["label"] == nil, mapped["contains_text"] == nil {
            mapped["contains_text"] = mapped["description"]
        }
        mapped["description"] = nil
        return TranslatedAction(studioTool: .assertVisible, studioArguments: mapped, approximate: true)
    }

    private static func translateAssertAbsent(_ arguments: [String: String]) -> TranslatedAction {
        var mapped = arguments
        let usesDescription = mapped["id"] == nil && mapped["label"] == nil && mapped["contains_text"] == nil
        if usesDescription {
            mapped["contains_text"] = mapped["description"]
        }
        mapped["description"] = nil
        return TranslatedAction(
            studioTool: .assertNotVisible,
            studioArguments: mapped,
            approximate: usesDescription
        )
    }

    private static func translateAssertEnabled(_ arguments: [String: String]) -> TranslatedAction {
        var mapped = arguments
        let usesDescription = mapped["id"] == nil && mapped["label"] == nil && mapped["contains_text"] == nil
        if usesDescription {
            mapped["contains_text"] = mapped["description"]
        }
        mapped["description"] = nil
        return TranslatedAction(
            studioTool: .assertEnabled,
            studioArguments: mapped,
            approximate: usesDescription
        )
    }

    private static func translateAssertValue(_ arguments: [String: String]) -> TranslatedAction? {
        // Studio's assert_text is exact equality. A contains-only assertion cannot be translated
        // without changing its meaning, so leave it out of the compiled plan and surface a warning.
        guard let expected = arguments["expected"] else { return nil }
        var mapped = arguments
        let usesDescription = mapped["id"] == nil && mapped["label"] == nil && mapped["contains_text"] == nil
        if usesDescription {
            mapped["contains_text"] = mapped["description"]
        }
        mapped["value"] = expected
        mapped["expected"] = nil
        mapped["contains"] = nil
        mapped["description"] = nil
        return TranslatedAction(
            studioTool: .assertText,
            studioArguments: mapped,
            approximate: usesDescription
        )
    }

    // swiftlint:disable cyclomatic_complexity

    /// Human-readable step text for the Studio test, one case per tool.
    ///
    /// Exhaustive over `StudioTool` on purpose: this used to fall through to a generic
    /// "Run <tool>." for anything it had not been taught, so a newly added tool produced a plan
    /// whose steps read as placeholders without failing anywhere a person would notice.
    private static func describe(
        tool: StudioTool,
        arguments: [String: String]
    ) -> (instruction: String, expected: String) {
        // Written as a loop rather than a chain of `??`: six optional-coalesces over a custom
        // subscript pushes the type-checker into "unable to type-check in reasonable time".
        let selectorKeys: [PlanArgument] = [.id, .label, .containsText, .description, .elementID, .elementLabel]
        let selector = selectorKeys.lazy.compactMap { arguments[$0] }.first
        switch tool {
        case .tapElement:
            return ("Tap element\(selector.map { " '\($0)'" } ?? "").", "Element is tapped.")
        case .setText:
            return ("Set text on element\(selector.map { " '\($0)'" } ?? "").", "Text field contains the given value.")
        case .typeText:
            return ("Type text.", "Text is entered.")
        case .swipeInDirection:
            let direction = arguments["direction"] ?? "unknown"
            return ("Swipe \(direction).", "View scrolls \(direction).")
        case .scroll:
            let direction = arguments["direction"] ?? "unknown"
            return ("Scroll \(direction).", "Content scrolls \(direction).")
        case .assertVisible:
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") is visible.", "Element is visible.")
        case .assertNotVisible:
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") is not visible.", "Element is not visible.")
        case .assertEnabled:
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") is enabled.", "Element is enabled.")
        case .assertText:
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") has expected text.", "Text matches.")
        case .takeScreenshot:
            return ("Take a screenshot.", "Screenshot is captured.")
        case .pressBack:
            return ("Press back.", "Previous screen is shown.")
        case .waitForElement:
            return ("Wait for element\(selector.map { " '\($0)'" } ?? "").", "Element appears.")
        }
    }

    // swiftlint:enable cyclomatic_complexity

    private struct ProcessedAction {
        let operation: StudioToolOperation?
        let step: StudioAuthoredTest.Step?
        let warnings: [SessionPlanWarning]
    }

    private static func process(
        index: Int,
        action: SessionAction,
        next: SessionAction?,
        retryCount: Int
    ) -> ProcessedAction {
        let transient = looksTransient(action)

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
        if translated.studioArguments.values.contains(where: { $0.hasPrefix("<redacted,") }) {
            warnings.append(SessionPlanWarning(
                kind: .redacted,
                actionIndex: index,
                toolName: action.toolName,
                reason: "contains a redacted value that must be hand-filled before replay or codegen"
            ))
        }
        if transient {
            warnings.append(SessionPlanWarning(
                kind: .approximate,
                actionIndex: index,
                toolName: action.toolName,
                reason: "targets system UI or a dismissable overlay; test-mode / mock builds usually "
                    + "suppress it — drop this step if yours does",
                transient: true
            ))
        }
        if retryCount > 1 {
            warnings.append(SessionPlanWarning(
                kind: .approximate,
                actionIndex: index,
                toolName: action.toolName,
                reason: "collapsed \(retryCount) consecutive identical taps (a retry loop) into one "
                    + "guarded step; the generated wait tolerates the load the taps were pushing through"
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
        guard precedesTransition, let selector = inspectionSelector(action) else {
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
    public static func compile(
        report: SessionReport,
        testName: String?,
        testDescription: String?
    ) throws -> CompileSessionToPlanResult {
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

        let (suppressed, retryCounts) = retryRuns(report.actions)
        func nextAction(after offset: Int) -> SessionAction? {
            var cursor = offset + 1
            while cursor < report.actions.count {
                if !suppressed.contains(cursor) {
                    return report.actions[cursor]
                }
                cursor += 1
            }
            return nil
        }
        var processed: [ProcessedAction] = []
        processed.reserveCapacity(report.actions.count)
        for (offset, action) in report.actions.enumerated() where !suppressed.contains(offset) {
            processed.append(process(
                index: offset,
                action: action,
                next: nextAction(after: offset),
                retryCount: retryCounts[offset] ?? 1
            ))
        }
        let toolOperations = processed.compactMap(\.operation)
        let steps = processed.compactMap(\.step)
        let warnings = processed.flatMap(\.warnings)

        let name = testName ?? "session-\(report.sessionID)"
        let description = testDescription
            ?? "Generated from session \(report.sessionID) (\(report.appID) on \(report.deviceID))"

        let studioTest = StudioAuthoredTest(
            formatVersion: 1,
            name: name,
            description: description,
            platform: platform,
            steps: steps,
            requirements: StudioTestRequirements(appId: report.appID, deviceName: report.deviceID),
            compiledPlan: StudioCompiledPlan(
                compiler: "session-compiler",
                compilerVersion: "1",
                toolOperations: toolOperations,
                // Persisted into the plan, not just returned alongside it, so a plan saved to disk
                // still knows what went missing when `amoo generate test` reads it back later.
                warnings: warnings.isEmpty ? [] : warnings
            )
        )

        return CompileSessionToPlanResult(testFlow: testFlow, studioTest: studioTest, warnings: warnings)
    }
}
