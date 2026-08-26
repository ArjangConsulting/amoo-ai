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
        let studioTool: String
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
    private static let directTranslations: Set<String> = [
        "tap_element", "set_text", "type_text", "swipe_in_direction", "scroll", "take_screenshot", "press_back"
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
        if directTranslations.contains(toolName) {
            return TranslatedAction(studioTool: toolName, studioArguments: arguments, approximate: false)
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
        return TranslatedAction(studioTool: "set_text", studioArguments: mapped, approximate: true)
    }

    private static func translateAssertVisible(_ arguments: [String: String]) -> TranslatedAction {
        var mapped = arguments
        if mapped["id"] == nil, mapped["label"] == nil, mapped["contains_text"] == nil {
            mapped["contains_text"] = mapped["description"]
        }
        mapped["description"] = nil
        return TranslatedAction(studioTool: "assert_visible", studioArguments: mapped, approximate: true)
    }

    private static func translateAssertAbsent(_ arguments: [String: String]) -> TranslatedAction {
        var mapped = arguments
        let usesDescription = mapped["id"] == nil && mapped["label"] == nil && mapped["contains_text"] == nil
        if usesDescription {
            mapped["contains_text"] = mapped["description"]
        }
        mapped["description"] = nil
        return TranslatedAction(
            studioTool: "assert_not_visible",
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
            studioTool: "assert_enabled",
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
            studioTool: "assert_text",
            studioArguments: mapped,
            approximate: usesDescription
        )
    }

    private static func describe(tool: String, arguments: [String: String]) -> (instruction: String, expected: String) {
        let selector = arguments["id"] ?? arguments["label"] ?? arguments["contains_text"]
            ?? arguments["description"] ?? arguments["element_id"] ?? arguments["element_label"]
        switch tool {
        case "tap_element":
            return ("Tap element\(selector.map { " '\($0)'" } ?? "").", "Element is tapped.")
        case "set_text":
            return ("Set text on element\(selector.map { " '\($0)'" } ?? "").", "Text field contains the given value.")
        case "type_text":
            return ("Type text.", "Text is entered.")
        case "swipe_in_direction":
            let direction = arguments["direction"] ?? "unknown"
            return ("Swipe \(direction).", "View scrolls \(direction).")
        case "scroll":
            let direction = arguments["direction"] ?? "unknown"
            return ("Scroll \(direction).", "Content scrolls \(direction).")
        case "assert_visible":
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") is visible.", "Element is visible.")
        case "assert_not_visible":
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") is not visible.", "Element is not visible.")
        case "assert_enabled":
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") is enabled.", "Element is enabled.")
        case "assert_text":
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") has expected text.", "Text matches.")
        case "take_screenshot":
            return ("Take a screenshot.", "Screenshot is captured.")
        case "press_back":
            return ("Press back.", "Previous screen is shown.")
        default:
            return ("Run \(tool).", "Step completes.")
        }
    }

    private struct ProcessedAction {
        let operation: StudioToolOperation?
        let step: StudioAuthoredTest.Step?
        let warnings: [SessionPlanWarning]
    }

    private static func process(index: Int, action: SessionAction) -> ProcessedAction {
        guard let translated = translate(toolName: action.toolName, arguments: action.arguments) else {
            let isQueryOnly = queryOnlyTools.contains(action.toolName)
            let warning = SessionPlanWarning(
                kind: isQueryOnly ? .notApplicable : .excluded,
                actionIndex: index,
                toolName: action.toolName,
                reason: isQueryOnly
                    ? "inspection-only tool with no effect on the app; intentionally omitted from compiledPlan"
                    : "no Studio tool equivalent; excluded from compiledPlan"
            )
            return ProcessedAction(operation: nil, step: nil, warnings: [warning])
        }

        var warnings: [SessionPlanWarning] = []
        if translated.approximate {
            warnings.append(SessionPlanWarning(
                kind: .approximate,
                actionIndex: index,
                toolName: action.toolName,
                reason: "translated to '\(translated.studioTool)' using an approximate selector mapping;"
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

        let stepID = "step-\(index)"
        let operation = StudioToolOperation(
            id: stepID,
            tool: translated.studioTool,
            arguments: translated.studioArguments
        )
        let described = describe(tool: translated.studioTool, arguments: translated.studioArguments)
        let step = StudioAuthoredTest.Step(id: stepID, instruction: described.instruction, expected: described.expected)
        return ProcessedAction(operation: operation, step: step, warnings: warnings)
    }

    public static func compile(
        report: SessionReport,
        testName: String?,
        testDescription: String?
    ) -> CompileSessionToPlanResult {
        let flowSteps = report.actions.map {
            CompiledSessionFlow.Step(tool: $0.toolName, arguments: $0.arguments)
        }
        let testFlow = CompiledSessionFlow(
            platform: report.platform,
            deviceID: report.deviceID,
            steps: flowSteps
        )

        let processed = report.actions.enumerated().map { process(index: $0.offset, action: $0.element) }
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
            platform: report.platform,
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
