import StudioProtocol
import TestSession

/// Per-tool argument remapping for the MCP tool names that need it. Split out of
/// `SessionPlanCompiler` to keep that type's body reviewable — these are mechanical
/// translations, one function per tool, with no shared state.
extension SessionPlanCompiler {
    /// MCP tool names that map 1:1 onto a Studio tool with no argument remapping needed.
    ///
    /// `scroll` is listed separately from `swipe_in_direction` on purpose, even though its
    /// `direction`/`distance` arguments look like a subset of the latter's. The two have *inverted*
    /// direction semantics: `scroll` names the direction the content moves (the companions
    /// implement `scroll(.down)` as a swipe-*up* gesture — see `XCUITestBridge.scroll` and
    /// `UIAutomatorBridge.scroll`), while `swipe_in_direction` names the raw finger direction.
    /// Collapsing them into one tool would silently reverse every recorded scroll.
    static let directTranslations: Set<StudioTool> = [
        .tapElement, .setText, .typeText, .swipeInDirection, .scroll, .scrollToElement, .takeScreenshot, .pressBack,
        .relaunchApplication
    ]

    /// A drag compiles only when both ends were recorded as elements. Coordinates alone cannot be
    /// replayed faithfully on another screen size, so a coordinate drag stays excluded.
    static func translateDrag(_ arguments: [String: String]) -> TranslatedAction? {
        let prefix = StudioToolOperation.dropTargetPrefix
        let probe = StudioToolOperation(id: "drag", tool: StudioTool.drag.rawValue, arguments: arguments)
        guard probe.hasSelector(), probe.hasSelector(prefix: prefix) else { return nil }
        var mapped: [String: String] = [:]
        for key in StudioToolOperation.selectorKeys {
            mapped[key] = arguments[key]
            mapped[prefix + key] = arguments[prefix + key]
        }
        mapped[.holdMilliseconds] = arguments[PlanArgument.holdMilliseconds.rawValue]
        mapped[.durationMilliseconds] = arguments[PlanArgument.durationMilliseconds.rawValue]
        return TranslatedAction(studioTool: .drag, studioArguments: mapped, approximate: false)
    }

    /// A pinch on an element, or on the whole app when neither an element nor a point was given.
    /// A pinch at a recorded point has no element to anchor it, so it stays excluded.
    static func translatePinch(_ arguments: [String: String]) -> TranslatedAction? {
        let probe = StudioToolOperation(id: "pinch", tool: StudioTool.pinch.rawValue, arguments: arguments)
        guard probe.hasSelector() || (arguments["x"] == nil && arguments["y"] == nil) else { return nil }
        var mapped: [String: String] = [:]
        for key in StudioToolOperation.selectorKeys {
            mapped[key] = arguments[key]
        }
        mapped[.scale] = arguments[PlanArgument.scale.rawValue]
        mapped[.velocity] = arguments[PlanArgument.velocity.rawValue]
        return TranslatedAction(studioTool: .pinch, studioArguments: mapped, approximate: false)
    }

    static func translateFillField(_ arguments: [String: String]) -> TranslatedAction {
        var mapped = arguments
        let usesDescription = mapped["id"] == nil && mapped["label"] == nil && mapped["contains_text"] == nil
        mapped["contains_text"] = mapped["contains_text"] ?? mapped["field_description"]
        mapped["field_description"] = nil
        return TranslatedAction(studioTool: .setText, studioArguments: mapped, approximate: usesDescription)
    }

    static func translateAssertVisible(_ arguments: [String: String]) -> TranslatedAction {
        var mapped = arguments
        // An id or label maps exactly; only a free-text `description` is a guess.
        let usesDescription = mapped["id"] == nil && mapped["label"] == nil && mapped["contains_text"] == nil
        if usesDescription {
            mapped["contains_text"] = mapped["description"]
        }
        mapped["description"] = nil
        return TranslatedAction(studioTool: .assertVisible, studioArguments: mapped, approximate: usesDescription)
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

    /// `expected` is normalised to an explicit `"true"` / `"false"`, so the plan always states the
    /// expectation. Anything else cannot be preserved, and returning `nil` makes the compiler report
    /// the assertion as unsupported rather than guess which state was meant.
    static func translateAssertSelected(_ arguments: [String: String]) -> TranslatedAction? {
        var mapped = arguments
        let expected = (arguments["expected"] ?? "true").lowercased()
        guard expected == "true" || expected == "false" else { return nil }
        mapped["expected"] = expected
        let usesDescription = mapped["id"] == nil && mapped["label"] == nil && mapped["contains_text"] == nil
        if usesDescription {
            mapped["contains_text"] = mapped["description"]
        }
        mapped["description"] = nil
        return TranslatedAction(
            studioTool: .assertSelected,
            studioArguments: mapped,
            approximate: usesDescription
        )
    }

    static func translateAssertChecked(_ arguments: [String: String]) -> TranslatedAction? {
        guard let selected = translateAssertSelected(arguments) else { return nil }
        return TranslatedAction(
            studioTool: .assertChecked, studioArguments: selected.studioArguments, approximate: selected.approximate
        )
    }

    static func translateAssertStateDescription(_ arguments: [String: String]) -> TranslatedAction? {
        guard (arguments["expected"] != nil) != (arguments["contains"] != nil),
              let value = translateAssertValue(arguments) else { return nil }
        return TranslatedAction(
            studioTool: .assertStateDescription, studioArguments: value.studioArguments, approximate: value.approximate
        )
    }

    static func translateAssertValue(_ arguments: [String: String]) -> TranslatedAction? {
        // `expected` is exact equality; `contains` is a substring check. Studio carries both, so
        // neither is left out of the plan.
        guard arguments["expected"] != nil || arguments["contains"] != nil else { return nil }
        var mapped = arguments
        let usesDescription = mapped["id"] == nil && mapped["label"] == nil && mapped["contains_text"] == nil
        if usesDescription {
            mapped["contains_text"] = mapped["description"]
        }
        if let expected = mapped["expected"] {
            mapped["value"] = expected
        }
        mapped["expected"] = nil
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
        case .drag:
            let target = [PlanArgument.id, .label, .containsText].lazy
                .compactMap { arguments[StudioToolOperation.dropTargetPrefix + $0.rawValue] }.first
            return (
                "Drag element\(selector.map { " '\($0)'" } ?? "") onto\(target.map { " '\($0)'" } ?? " the target").",
                "Element is dropped on the target."
            )
        case .pinch:
            let zoom = Double(arguments[.scale] ?? "").map { $0 > 1 ? "in" : "out" } ?? "in or out"
            return (
                "Pinch to zoom \(zoom) on \(selector.map { "element '\($0)'" } ?? "the app").",
                "Content zooms \(zoom)."
            )
        case .assertVisible:
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") is visible.", "Element is visible.")
        case .assertNotVisible:
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") is not visible.", "Element is not visible.")
        case .assertEnabled:
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") is enabled.", "Element is enabled.")
        case .assertChecked:
            return ("Assert native checked state.", "Checked state matches the explicit expectation.")
        case .assertStateDescription:
            return ("Assert native state description.", "State description matches the explicit expectation.")
        case .assertSelected:
            let state = arguments[.expected]?.lowercased() == "false" ? "not selected" : "selected"
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") is \(state).", "Element is \(state).")
        case .assertText:
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") has expected text.", "Text matches.")
        case .assertValue:
            return ("Assert element\(selector.map { " '\($0)'" } ?? "") has expected value.", "Value matches.")
        case .takeScreenshot:
            return ("Take a screenshot.", "Screenshot is captured.")
        case .relaunchApplication:
            return ("Relaunch the application preserving stored state.", "Stored state survives relaunch.")
        case .pressBack:
            return ("Press back.", "Previous screen is shown.")
        case .scrollToElement:
            return ("Scroll to element\(selector.map { " '\($0)'" } ?? "").", "Element is on screen.")
        case .waitForElement:
            return ("Wait for element\(selector.map { " '\($0)'" } ?? "").", "Element appears.")
        }
    }

    // swiftlint:enable cyclomatic_complexity
}
