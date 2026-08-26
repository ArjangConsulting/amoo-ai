import Foundation

/// The vocabulary a compiled Studio plan may use.
///
/// This exists because the same tool names used to be spelled out as string literals in eight
/// places — the session compiler's translation table and its step-description switch, the AI plan
/// allow-list, the prompt text, and a switch in each of the three emitters. Adding a tool meant
/// remembering all eight, and twice it did not happen: `assert_enabled` and `scroll` each shipped
/// missing from one site, which silently dropped recorded steps out of generated tests rather than
/// failing anywhere a person would notice.
///
/// Switching over this enum without a `default` makes that class of omission a compile error: add
/// a case, and every emitter that cannot yet handle it stops building.
///
/// `StudioToolOperation.tool` stays a `String` on the wire, because AI-authored plans can contain
/// anything. Parsing happens at the boundary — same shape as `Platform`, where leniency lives in
/// one place and everything downstream is typed.
public enum StudioTool: String, CaseIterable, Codable, Sendable, Hashable {
    case tapElement = "tap_element"
    case setText = "set_text"
    case typeText = "type_text"
    case swipeInDirection = "swipe_in_direction"
    case scroll
    case waitForElement = "wait_for_element"
    case assertVisible = "assert_visible"
    case assertNotVisible = "assert_not_visible"
    case assertText = "assert_text"
    case assertEnabled = "assert_enabled"
    case takeScreenshot = "take_screenshot"
    case pressBack = "press_back"

    /// Every tool name a plan may contain, for validating AI-proposed plans and for the prompt that
    /// tells the model what it may emit. Derived from the cases so the two cannot drift.
    public static let allNames: [String] = allCases.map(\.rawValue)
}

/// Argument keys a `StudioToolOperation` may carry.
///
/// Same motivation as `StudioTool`, minus the exhaustiveness: these are dictionary lookups, so the
/// win here is that a typo is a compile error rather than a silently-nil argument that turns into a
/// missing selector at run time.
public enum PlanArgument: String, Sendable {
    case id
    case label
    case containsText = "contains_text"
    case elementID = "element_id"
    case elementLabel = "element_label"
    case description
    case value
    case expected
    case text
    case direction
    case distance
    case timeoutMilliseconds = "timeout_ms"
    case fieldDescription = "field_description"
    case contains
}

public extension [String: String] {
    /// Reads an operation argument by its typed key.
    subscript(argument: PlanArgument) -> String? {
        get { self[argument.rawValue] }
        set { self[argument.rawValue] = newValue }
    }
}
