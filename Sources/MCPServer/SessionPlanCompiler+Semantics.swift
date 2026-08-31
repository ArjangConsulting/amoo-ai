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
    /// observation still carries the element's label, which is what the code generator needs to name
    /// a readable local variable — the id stays the selector, the label is a naming hint.
    static let idSelectorTools: Set<String> = [
        "tap_element", "double_tap", "long_press", "set_text", "type_text", "fill_field",
        "assert_visible", "assert_absent", "wait_for_element", "assert_enabled",
        "assert_text", "assert_value"
    ]

    static func attachObservedLabel(_ action: SessionAction, recentElements: [RecordedElement])
        -> SessionAction {
        guard idSelectorTools.contains(action.toolName),
              let id = action.arguments["id"], !id.isEmpty,
              (action.arguments["label"] ?? "").isEmpty,
              let observed = recentElements.first(where: { $0.id == id }),
              let label = observed.label, !label.isEmpty else { return action }
        var arguments = action.arguments
        arguments["label"] = label
        if let elementType = observed.elementType, arguments["element_type"] == nil {
            arguments["element_type"] = elementType
        }
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
        // (`cigarettesHabitRow`, not `habitCatalogRow`).
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

    static func semanticTestName(for report: SessionReport) -> String {
        var words: [String] = []
        if report.launchEnvironment.keys.contains(where: { $0.localizedCaseInsensitiveContains("SKIP_ONBOARDING") }) {
            words += ["skip", "onboarding"]
        }
        let tools = report.actions.map(\.toolName)
        if tools.contains("swipe") {
            words.append("delete")
        }
        if report.actions.contains(where: {
            $0
                .toolName == "tap_element" &&
                ($0.arguments["label"] == "Add" || $0.arguments["id"]?.contains("create") == true)
        }) {
            words += ["and", "add", "habit"]
        }
        if words.isEmpty {
            words = ["recorded", "flow"]
        }
        return words.enumerated().map { index, word in
            index == 0 ? word : word.prefix(1).uppercased() + word.dropFirst()
        }.joined()
    }
}
