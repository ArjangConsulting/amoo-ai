import StudioProtocol
import TestSession

/// Per-tool argument remapping for the MCP tool names that need it. Split out of
/// `SessionPlanCompiler` to keep that type's body reviewable — these are mechanical
/// translations, one function per tool, with no shared state.
extension SessionPlanCompiler {
    static func translateFillField(_ arguments: [String: String]) -> TranslatedAction {
        var mapped = arguments
        mapped["contains_text"] = mapped["contains_text"] ?? mapped["field_description"]
        mapped["field_description"] = nil
        return TranslatedAction(studioTool: .setText, studioArguments: mapped, approximate: true)
    }

    static func translateAssertVisible(_ arguments: [String: String]) -> TranslatedAction {
        var mapped = arguments
        if mapped["id"] == nil, mapped["label"] == nil, mapped["contains_text"] == nil {
            mapped["contains_text"] = mapped["description"]
        }
        mapped["description"] = nil
        return TranslatedAction(studioTool: .assertVisible, studioArguments: mapped, approximate: true)
    }

    static func translateAssertAbsent(_ arguments: [String: String]) -> TranslatedAction {
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

    static func translateAssertEnabled(_ arguments: [String: String]) -> TranslatedAction {
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

    static func translateAssertValue(_ arguments: [String: String]) -> TranslatedAction? {
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
            studioTool: .assertValue,
            studioArguments: mapped,
            approximate: usesDescription
        )
    }

    // swiftlint:disable cyclomatic_complexity

    /// Human-readable step text for the Studio test, one case per tool.
    ///
    /// Exhaustive over `StudioTool` on purpose: this used to fall through to a generic
    /// "Run <tool>." for anything it had not been taught, so a newly added tool produced a plan
    /// whose steps read as placeholders without failing anywhere a person would notice. One case
    /// per tool is the point here, so the complexity count is expected rather than a smell.
    static func describe(
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
        case .assertValue:
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") has expected value.", "Value matches.")
        case .takeScreenshot:
            return ("Take a screenshot.", "Screenshot is captured.")
        case .pressBack:
            return ("Press back.", "Previous screen is shown.")
        case .waitForElement:
            return ("Wait for element\(selector.map { " '\($0)'" } ?? "").", "Element appears.")
        }
    }

    // swiftlint:enable cyclomatic_complexity
}
