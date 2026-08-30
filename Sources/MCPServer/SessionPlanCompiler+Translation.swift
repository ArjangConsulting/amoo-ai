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
            studioTool: .assertText,
            studioArguments: mapped,
            approximate: usesDescription
        )
    }
}
