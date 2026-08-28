import StudioProtocol
import TestSession

/// Heuristics that let `SessionPlanCompiler` carry more of a recording's intent into the plan:
/// turning a trailing inspection into an assertion, writing an actionable message for a coordinate
/// tap, tagging system-UI steps as transient, and collapsing a retry-tap loop into one step.
extension SessionPlanCompiler {
    /// Tools that change what is on screen, as opposed to querying or asserting. A recorded
    /// inspection immediately before one of these usually stood in for "I checked X was here first",
    /// so that trailing inspection is compiled into an assertion rather than dropped.
    static let stateChangingTools: Set<String> = [
        "tap_element", "tap", "double_tap", "long_press",
        "set_text", "type_text", "fill_field",
        "swipe", "swipe_in_direction", "scroll", "press_back"
    ]

    static func isTransition(_ action: SessionAction) -> Bool {
        stateChangingTools.contains(action.toolName)
    }

    /// Substrings that mark an action as touching system UI or a dismissable overlay. Deliberately
    /// narrow: a false positive tells the finalize pass that a real step is disposable.
    static let transientMarkers: [String] = [
        "com.apple.springboard", "springboard", "sign in with apple", "system alert",
        "permission", "allow notifications", "app tracking transparency", "att prompt",
        "location permission", "camera permission", "microphone permission", "photo permission",
        "paywall", "coach mark", "coachmark", "tooltip", "onboarding tooltip"
    ]

    static func looksTransient(_ action: SessionAction) -> Bool {
        let haystack = ([action.toolName] + Array(action.arguments.values)).map { $0.lowercased() }
        return transientMarkers.contains { marker in haystack.contains { $0.contains(marker) } }
    }

    /// The Studio selector an inspection tool queried by, if any — the basis for turning the
    /// inspection into an assertion. Prefers an identifier, then an accessibility label, then text.
    static func inspectionSelector(_ action: SessionAction) -> [String: String]? {
        let args = action.arguments
        if let id = args["id"] ?? args["element_id"], !id.isEmpty {
            return ["id": id]
        }
        if let label = args["label"] ?? args["element_label"], !label.isEmpty {
            return ["label": label]
        }
        for key in ["contains_text", "text", "query", "description"] {
            if let value = args[key], !value.isEmpty {
                return ["contains_text": value]
            }
        }
        return nil
    }

    static func isCoordinateGesture(_ toolName: String) -> Bool {
        ["tap", "double_tap", "long_press", "swipe"].contains(toolName)
    }

    static func coordinateDescription(_ arguments: [String: String]) -> String? {
        if let x = arguments["x"], let y = arguments["y"] {
            return "(\(x), \(y))"
        }
        if let x = arguments["from_x"], let y = arguments["from_y"] {
            return "(\(x), \(y))"
        }
        return nil
    }

    /// A coordinate gesture that survived into the recording almost always means the target had no
    /// identifier, or its accessibility children were merged into an ancestor. Say that, and say
    /// what to do about it — "no Studio tool equivalent" points the reader nowhere.
    static func excludedReason(for action: SessionAction) -> String {
        guard isCoordinateGesture(action.toolName) else {
            return "no Studio tool equivalent; excluded from compiledPlan"
        }
        let point = coordinateDescription(action.arguments).map { " at \($0)" } ?? ""
        return "raw coordinate \(action.toolName)\(point); the target had no accessibility identifier, "
            + "or its a11y children were merged into an ancestor "
            + "(SwiftUI .accessibilityElement(children: .combine) / merged Compose semantics). "
            + "Add an identifier to the tapped element, or drive it through an addressable ancestor, "
            + "then re-record rather than passing --allow-incomplete."
    }

    /// The 2nd..Nth identical `tap_element` of a retry run (a user hammering a button past a flaky
    /// load), mapped to the run's first index. The finalize path emits one guarded step per run —
    /// its wait tolerates the load the taps were pushing through — while the literal `testFlow`
    /// still replays every recorded tap.
    static func retryRuns(_ actions: [SessionAction]) -> (suppressed: Set<Int>, counts: [Int: Int]) {
        var suppressed: Set<Int> = []
        var counts: [Int: Int] = [:]
        var index = 0
        while index < actions.count {
            let action = actions[index]
            guard action.toolName == "tap_element" else {
                index += 1
                continue
            }
            var runEnd = index + 1
            while runEnd < actions.count,
                  actions[runEnd].toolName == "tap_element",
                  actions[runEnd].arguments == action.arguments {
                suppressed.insert(runEnd)
                runEnd += 1
            }
            if runEnd - index > 1 {
                counts[index] = runEnd - index
            }
            index = runEnd
        }
        return (suppressed, counts)
    }
}
