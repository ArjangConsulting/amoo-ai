import StudioProtocol
import TestSession

/// Advisory checks for recordings that compile but can pass without proving the intended state.
public enum SessionPlanQualityReview {
    public static func warnings(for actions: [SessionAction]) -> [StudioPlanWarning] {
        var result: [StudioPlanWarning] = []
        var observed = Set<String>()
        var lastMutation: Int?
        for (index, action) in actions.enumerated() where !action.isError {
            let tool = action.toolName
            let target = selector(action.arguments)
            if tool.hasPrefix("assert_") {
                if tool == "assert_absent", let target, !observed.contains(target) {
                    result.append(warning(
                        index,
                        tool,
                        "Absence has no prior positive assertion for this target; "
                            + "verify the starting state or assert the resulting state."
                    ))
                }
                if tool == "assert_visible", let target {
                    observed.insert(target)
                }
                lastMutation = nil
            }
            if ["tap_element", "set_text", "type_text", "press_back", "swipe_in_direction"].contains(tool) {
                lastMutation = index
                if tool != "type_text", action.arguments["element_id"] == nil, action.arguments["id"] == nil,
                   target != nil {
                    result.append(warning(
                        index,
                        tool,
                        "Visible-copy selector depends on locale; prefer a stable accessibility identifier."
                    ))
                }
            }
        }
        if let index = lastMutation {
            result.append(warning(
                index,
                actions[index].toolName,
                "Final mutation has no following semantic assertion; "
                    + "verify its result, including cleanup such as signing out."
            ))
        }
        return result
    }

    private static func selector(_ arguments: [String: String]) -> String? {
        for key in ["element_id", "id", "element_label", "label", "text", "contains_text"] {
            if let value = arguments[key], !value.isEmpty {
                let category = ["element_id", "id"].contains(key) ? "id" : "label"
                return "\(category):\(value)"
            }
        }
        return nil
    }

    private static func warning(_ index: Int, _ tool: String, _ reason: String) -> StudioPlanWarning {
        StudioPlanWarning(kind: .approximate, actionIndex: index, toolName: tool, reason: reason)
    }
}
