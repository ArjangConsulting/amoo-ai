import Foundation
import StudioProtocol
import TestSession

/// Semantic enrichment the compiler applies to recorded actions before `process` sees them:
/// binding a coordinate swipe back to the element `find_elements` resolved, carrying an observed
/// label onto an id-only selector so generated variable names stay readable, and deriving a
/// fallback test name. Split out of `SessionPlanCompiler.swift` to keep that file within the
/// `file_length` budget.
extension SessionPlanCompiler {
    /// Selector-based element actions the recorder stores id-only. A matching `find_elements`
    /// observation still carries the element's label and type, which is what the code generator
    /// needs to name a readable local variable — the id stays the selector.
    static let idSelectorTools: Set<String> = [
        "tap_element", "double_tap", "long_press", "set_text", "type_text", "fill_field",
        "assert_visible", "assert_absent", "wait_for_element", "assert_enabled",
        "assert_text", "assert_value"
    ]

    /// Copies the label/type from the `find_elements` observation of this action's target onto the
    /// action as *naming* hints — never as the selector. The hint goes in `name_hint`, a key the
    /// code generator reads for variable names but `describe()` and the query logic ignore, so the
    /// recorded step text and the selector both stay keyed on the id.
    ///
    /// Skipped when the id is already a clean self-descriptive token (`trash`, `checkmark`): a hint
    /// of "Delete" there would collide with a neighbouring "Delete" text element into
    /// `delete` / `delete2`, where the bare id gives the clearer `trash`.
    static func attachObservedLabel(_ action: SessionAction, recentElements: [RecordedElement])
        -> SessionAction {
        guard idSelectorTools.contains(action.toolName),
              let id = action.arguments["id"], !id.isEmpty,
              action.arguments["name_hint"] == nil,
              !isSelfDescriptiveIdentifier(id),
              let observed = recentElements.first(where: { $0.id == id }) else { return action }
        var arguments = action.arguments
        if let label = observed.label, !label.isEmpty, (arguments["label"] ?? "").isEmpty {
            arguments["name_hint"] = label
        }
        if let elementType = observed.elementType, arguments["element_type"] == nil {
            arguments["element_type"] = elementType
        }
        guard arguments != action.arguments else { return action }
        return SessionAction(
            timestamp: action.timestamp,
            toolName: action.toolName,
            arguments: arguments,
            result: action.result,
            isError: action.isError,
            intent: action.intent,
            observedElements: action.observedElements,
            gestureTarget: action.gestureTarget
        )
    }

    /// An element-scoped `swipe_in_direction` / `scroll` that the recorder stored id-only. The
    /// matching `find_elements` observation still carries the row's label, which is what makes the
    /// generated gesture read `laundryTaskRow.swipeLeft()` rather than `taskListRow.swipeLeft()`.
    /// The `element_id` stays the selector — the label is a naming hint only.
    static func attachGestureTargetLabel(_ action: SessionAction, recentElements: [RecordedElement])
        -> SessionAction {
        guard ["swipe_in_direction", "scroll"].contains(action.toolName),
              let id = action.arguments["element_id"], !id.isEmpty,
              (action.arguments["element_label"] ?? "").isEmpty,
              let observed = recentElements.first(where: { $0.id == id }) else { return action }
        var arguments = action.arguments
        if let label = observed.label, !label.isEmpty {
            arguments["element_label"] = label
        }
        if let elementType = observed.elementType, arguments["element_type"] == nil {
            arguments["element_type"] = elementType
        }
        guard arguments != action.arguments else { return action }
        return SessionAction(
            timestamp: action.timestamp,
            toolName: action.toolName,
            arguments: arguments,
            result: action.result,
            isError: action.isError,
            intent: action.intent,
            observedElements: action.observedElements,
            gestureTarget: action.gestureTarget
        )
    }

    /// Distinguishes two identically-labelled elements that play different roles by the shape of the
    /// flow around them. A bare-label `tap_element` that sits between a "create / add / new" trigger
    /// and a later "add / save / done / confirm" tap is selecting one option on a creation screen —
    /// a *preset option* — not the catalog row of the same name. Naming it `laundryPresetOption` keeps
    /// it from colliding with `laundryTaskRow` (or degrading to `laundry` / `laundry2`).
    ///
    /// Writes `name_hint`, a naming-only key: the selector (`label`) and the recorded step text are
    /// untouched. Deterministic — it depends only on the ordered operations, never on wall-clock or
    /// iteration order.
    static func annotatePresetOptionTaps(_ operations: [StudioToolOperation]) -> [StudioToolOperation] {
        guard let triggerIndex = operations.firstIndex(where: isCreationTrigger) else { return operations }
        return operations.enumerated().map { index, operation in
            guard index > triggerIndex,
                  operation.tool == StudioTool.tapElement.rawValue,
                  (operation.arguments["id"] ?? "").isEmpty,
                  operation.arguments["name_hint"] == nil,
                  let label = operation.arguments["label"], !label.isEmpty,
                  operations[(index + 1)...].contains(where: isConfirmationTap) else { return operation }
            var arguments = operation.arguments
            arguments["name_hint"] = "\(label) preset option"
            return StudioToolOperation(
                id: operation.id,
                tool: operation.tool,
                arguments: arguments,
                helper: operation.helper
            )
        }
    }

    private static func isCreationTrigger(_ operation: StudioToolOperation) -> Bool {
        guard operation.tool == StudioTool.tapElement.rawValue else { return false }
        let haystack = [operation.arguments["id"], operation.arguments["label"]]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return ["create", "add ", "add_", "new", "plus"].contains { haystack.contains($0) }
            || haystack == "add" || haystack.hasSuffix(" add")
    }

    private static func isConfirmationTap(_ operation: StudioToolOperation) -> Bool {
        guard operation.tool == StudioTool.tapElement.rawValue else { return false }
        let label = (operation.arguments["label"] ?? "").lowercased()
        let id = (operation.arguments["id"] ?? "").lowercased()
        return ["add", "save", "done", "confirm", "ok", "create"].contains(label)
            || ["checkmark", "done", "save", "confirm", "create"].contains { id.contains($0) }
    }

    /// `trash`, `checkmark`, `submitButton` — a single, non-namespaced identifier that is already a
    /// readable all-letter word needs no naming hint. `app.task_list.create_button`, `btn_1`,
    /// `e5f2` do not qualify and still take the label.
    static func isSelfDescriptiveIdentifier(_ id: String) -> Bool {
        guard !id.contains(".") else { return false }
        let letters = id.filter(\.isLetter)
        return letters.count >= 4 && letters.count == id.count
    }

    /// Turns a recorded point swipe back into the element gesture the user performed when the
    /// recent structured observation identifies an unambiguous target. Text parsing is isolated in
    /// `legacyRecordedElements` and exists only for reports written before structured observations.
    static func semanticCoordinateSwipe(_ action: SessionAction, recentElements: [RecordedElement])
        -> SessionAction {
        guard action.toolName == "swipe",
              let fromX = action.arguments["from_x"].flatMap(Double.init),
              let fromY = action.arguments["from_y"].flatMap(Double.init),
              let toX = action.arguments["to_x"].flatMap(Double.init),
              let toY = action.arguments["to_y"].flatMap(Double.init) else { return action }
        let target = action.gestureTarget
            ?? TestSession.resolveTarget(at: RecordedPoint(x: fromX, y: fromY), from: recentElements)
        guard let target, target.elementID?.isEmpty == false || target.elementLabel?.isEmpty == false else {
            return action
        }
        let dx = toX - fromX, dy = toY - fromY
        let direction = abs(dx) >= abs(dy) ? (dx < 0 ? "left" : "right") : (dy < 0 ? "up" : "down")
        var arguments = action.arguments
        arguments["direction"] = direction
        arguments["element_id"] = target.elementID
        // Keep the resolved label even when an id drives the selector: the id stays the stable test
        // contract, but the label is what makes the generated variable name readable
        // (`groceriesTaskRow`, not `taskListRow`).
        arguments["element_label"] = target.elementLabel
        arguments["element_type"] = target.elementType
        for key in ["from_x", "from_y", "to_x", "to_y"] {
            arguments[key] = nil
        }
        return SessionAction(
            timestamp: action.timestamp,
            toolName: "swipe_in_direction",
            arguments: arguments,
            result: action.result,
            isError: action.isError,
            intent: action.intent,
            observedElements: action.observedElements,
            gestureTarget: target
        )
    }

    static func legacyRecordedElements(from result: String) -> [RecordedElement] {
        let plainResult = result.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
        let pattern = #"\[([^\]]+)\].*?hitPoint: \(([0-9.]+),([0-9.]+)\) pts ([0-9.]+)x([0-9.]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: plainResult, range: NSRange(plainResult.startIndex..., in: plainResult)).compactMap {
            guard let idRange = Range($0.range(at: 1), in: plainResult),
                  let xRange = Range($0.range(at: 2), in: plainResult),
                  let yRange = Range($0.range(at: 3), in: plainResult),
                  let widthRange = Range($0.range(at: 4), in: plainResult),
                  let heightRange = Range($0.range(at: 5), in: plainResult),
                  let x = Double(plainResult[xRange]), let y = Double(plainResult[yRange]),
                  let width = Double(plainResult[widthRange]), let height = Double(plainResult[heightRange]) else {
                return nil
            }
            // The text format reports only the hit point and the size, so the frame is
            // reconstructed assuming the hit point is the frame centre. That is exact for most
            // controls and close enough for the containment/nearest checks in `resolveTarget`;
            // recordings with structured `observedElements` carry the real frame and never hit
            // this path.
            return RecordedElement(
                id: String(plainResult[idRange]),
                label: nil,
                frame: RecordedRect(
                    x: x - width / 2,
                    y: y - height / 2,
                    width: width,
                    height: height
                ),
                hitPoint: RecordedPoint(x: x, y: y)
            )
        }
    }

    static func invalidatesRecordedGeometry(_ tool: String) -> Bool {
        [
            "tap",
            "tap_element",
            "double_tap",
            "long_press",
            "swipe",
            "swipe_in_direction",
            "scroll",
            "drag",
            "type_text",
            "set_text",
            "fill_field",
            "press_back",
            "device_launch_app"
        ].contains(tool)
    }

    /// Last-resort name when neither the caller nor the recording named the test. Deliberately
    /// neutral: the recorder does not know the user's intent — only the driving agent does, via
    /// `compile_session_to_plan`'s `test_name` or `amoo generate test --test-name`. Guessing a verb
    /// ("delete", "add") from the tool mix produces confident, wrong names on any other flow, so
    /// this reports only what is certain — a leading skip-onboarding launch flag — then `flow`.
    /// Collisions between generated files are handled by `amoo generate test`'s numeric suffixing.
    static func semanticTestName(for report: SessionReport) -> String {
        let skipsOnboarding = report.launchEnvironment.keys
            .contains { $0.localizedCaseInsensitiveContains("SKIP_ONBOARDING") }
        let words = skipsOnboarding ? ["skip", "onboarding", "flow"] : ["recorded", "flow"]
        return words.enumerated().map { index, word in
            index == 0 ? word : word.prefix(1).uppercased() + word.dropFirst()
        }.joined()
    }
}
