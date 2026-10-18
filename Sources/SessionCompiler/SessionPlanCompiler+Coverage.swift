import StudioProtocol
import TestSession

/// Warnings that say what a recording's behavioral checks became in the plan.
///
/// A generic "inspection-only" note does not tell a reviewer whether a recorded selection was
/// asserted, approximated as a visibility check, or left out entirely, and that is exactly what
/// decides whether the generated test can fail when the behavior breaks. Each helper here attaches
/// a `StudioPlanWarning.Category` plus the selector and state involved, reusing the one warning type
/// the plan already persists.
extension SessionPlanCompiler {
    /// Tools that author an expectation about the app, as opposed to observing or driving it.
    static let assertionTools: Set<String> = [
        "assert_visible", "assert_absent", "assert_enabled", "assert_value", "assert_selected",
        "assert_screen_changed", "assert_accessibility_journey"
    ]

    /// Selector fields a recorded call can carry, in the order they are reported.
    private static let selectorFieldOrder = [
        "id", "label", "contains_text", "description", "field_description", "parent_id",
        "element_id", "element_label", "index", "first"
    ]

    /// Fields whose value must reach the plan unchanged, or the compiled selector means something else.
    private static let exactSelectorFields = [
        "id", "label", "contains_text", "parent_id", "element_id", "element_label", "index", "first"
    ]

    /// `id=…, contains_text=…` for the selector fields in `arguments`, or `nil` when it has none.
    static func selectorSummary(_ arguments: [String: String]) -> String? {
        let parts = selectorFieldOrder.compactMap { key -> String? in
            guard let value = arguments[key], !value.isEmpty else { return nil }
            return "\(key)=\(value)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The selector fields a recorded call carried that the compiled operation no longer states.
    ///
    /// Reported so a constraint is never lost without a trace: an emitter that honors only some of
    /// a selector's fields would otherwise match a different element than the recording did.
    static func discardedSelectorFields(
        recorded: [String: String],
        planned: [String: String]
    ) -> [String] {
        var dropped = exactSelectorFields.filter { key in
            guard let value = recorded[key], !value.isEmpty else { return false }
            return planned[key] != value
        }
        let hasExact = ["id", "label", "contains_text"].contains { !(recorded[$0] ?? "").isEmpty }
        for key in ["description", "field_description"] {
            // A description alone becomes `contains_text` (flagged as approximate); next to an exact
            // constraint it has nowhere to go.
            if hasExact, let value = recorded[key], !value.isEmpty, planned[key] != value {
                dropped.append(key)
            }
        }
        return dropped
    }

    /// How many of `id`, `label` and `contains_text` the call constrains by.
    static func exactConstraintCount(_ arguments: [String: String]) -> Int {
        ["id", "label", "contains_text"].filter { !(arguments[$0] ?? "").isEmpty }.count
    }

    /// Warnings for a recorded action that translated into a plan operation.
    static func coverageWarnings(
        index: Int,
        action: SessionAction,
        translated: TranslatedAction
    ) -> [SessionPlanWarning] {
        var warnings: [SessionPlanWarning] = []
        let isAssertion = assertionTools.contains(action.toolName)
        let selector = selectorSummary(action.arguments)

        let dropped = discardedSelectorFields(recorded: action.arguments, planned: translated.studioArguments)
        if !dropped.isEmpty {
            warnings.append(SessionPlanWarning(
                kind: .approximate,
                actionIndex: index,
                toolName: action.toolName,
                reason: "selector field(s) \(dropped.joined(separator: ", ")) are not part of the compiled"
                    + " selector, so the generated test matches a different element set than the recording did",
                category: .selectorConstraintDiscarded,
                selector: selector
            ))
        }
        if translated.studioTool == .assertSelected || (isAssertion && exactConstraintCount(action.arguments) > 1) {
            let state = translated.studioArguments["expected"].map { "expected selected=\($0)" }
            warnings.append(SessionPlanWarning(
                kind: .preserved,
                actionIndex: index,
                toolName: action.toolName,
                reason: "explicit assertion carried into the plan as '\(translated.studioTool.rawValue)'"
                    + (state.map { " (\($0))" } ?? "") + " with every selector constraint",
                category: .assertionPreserved,
                selector: selector,
                state: state
            ))
        }
        return warnings
    }

    /// The selected elements an observation reported, as `name: selected=true` text.
    ///
    /// Only a `true` is reported. iOS reports `selected=false` for every button and cell, so flagging
    /// those would bury the observations that matter: an element seen selected is exactly where a
    /// missing `assert_selected` leaves the generated test unable to fail.
    static func observedSelectedState(_ action: SessionAction) -> String? {
        let states = action.observedElements.compactMap { element -> String? in
            guard element.isSelected == true else { return nil }
            let name = element.id ?? element.label ?? "element"
            return "\(name): selected=true"
        }
        return states.isEmpty ? nil : states.joined(separator: "; ")
    }

    /// The note for an observation that read a selected state. Nothing asserts it, and saying so
    /// plainly is the point: the plan has no check that would fail if the state were wrong.
    static func selectedStateNotAsserted(index: Int, action: SessionAction, state: String) -> SessionPlanWarning {
        SessionPlanWarning(
            kind: .approximate,
            actionIndex: index,
            toolName: action.toolName,
            reason: "observation read a selected state (\(state)) but nothing asserts it; the generated test"
                + " would pass whether or not the selection happened. Use assert_selected with"
                + " expected=true|false to author the check",
            category: .selectedStateNotAsserted,
            selector: selectorSummary(action.arguments),
            state: state
        )
    }
}
