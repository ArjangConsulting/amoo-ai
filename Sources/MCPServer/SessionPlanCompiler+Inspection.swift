import Foundation
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

    /// Phrases specific enough to mean system UI wherever they appear — a bundle identifier or a
    /// system-authored prompt title. Safe to match against any argument value.
    static let systemUIMarkers: [String] = [
        "com.apple.springboard", "sign in with apple", "system alert", "allow notifications",
        "app tracking transparency", "att prompt", "location permission", "camera permission",
        "microphone permission", "photo permission", "notification permission"
    ]

    /// Words that suggest a dismissable overlay but are perfectly ordinary inside an app's own
    /// identifiers — an app whose feature *is* the paywall, or a `settings.permissions.row`. These
    /// match only whole words in human-facing text, never inside an accessibility identifier, since
    /// a false positive tells the finalize pass that a real step is disposable.
    static let overlayMarkers: [[String]] = [
        ["paywall"], ["coach", "mark"], ["coachmark"], ["tooltip"], ["upsell"]
    ]

    /// Argument keys carrying text a person wrote for a person to read, as opposed to a selector.
    private static let humanFacingArgumentKeys: Set<String> = [
        "label", "element_label", "text", "contains_text", "element_contains_text",
        "description", "title", "message"
    ]

    static func looksTransient(_ action: SessionAction) -> Bool {
        let allValues = ([action.toolName] + Array(action.arguments.values)).map { $0.lowercased() }
        if systemUIMarkers.contains(where: { marker in allValues.contains { $0.contains(marker) } }) {
            return true
        }
        let humanFacing = action.arguments
            .filter { humanFacingArgumentKeys.contains($0.key) }
            .flatMap { words($0.value) }
        return overlayMarkers.contains { contains(humanFacing, run: $0) }
    }

    /// Lowercased word tokens, splitting on non-alphanumerics and camel humps.
    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).flatMap { chunk -> [String] in
            var tokens: [String] = []
            var current = ""
            for character in chunk {
                if character.isUppercase, current.isEmpty == false {
                    tokens.append(current)
                    current = ""
                }
                current.append(character)
            }
            if current.isEmpty == false {
                tokens.append(current)
            }
            return tokens.map { $0.lowercased() }
        }
    }

    private static func contains(_ tokens: [String], run: [String]) -> Bool {
        guard run.isEmpty == false, tokens.count >= run.count else { return false }
        return tokens.indices.dropLast(run.count - 1).contains { start in
            Array(tokens[start ..< start + run.count]) == run
        }
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

    static func transientWarning(index: Int, toolName: String) -> SessionPlanWarning {
        SessionPlanWarning(
            kind: .approximate,
            actionIndex: index,
            toolName: toolName,
            reason: "targets system UI or a dismissable overlay; test-mode / mock builds usually "
                + "suppress it — drop this step if yours does",
            transient: true
        )
    }

    /// Says outright that the collapse is an inference, and shows the numbers behind it. A
    /// cumulative tap run read as a retry loop changes what the test asserts, so the reader needs
    /// both the verdict and the evidence — the gaps and the threshold they were compared against.
    static func retryWarning(
        index: Int,
        toolName: String,
        retryCount: Int,
        interval: TimeInterval,
        gaps: [Double]
    ) -> SessionPlanWarning {
        let gapText = gaps.map { String(format: "%.2fs", $0) }.joined(separator: ", ")
        return SessionPlanWarning(
            kind: .approximate,
            actionIndex: index,
            toolName: toolName,
            reason: "\(retryCount) identical taps \(gapText.isEmpty ? "" : "(gaps \(gapText)) ")"
                + "all within the \(String(format: "%.2fs", interval)) retry window, so they were "
                + "read as a retry loop and collapsed into one guarded step. If they were "
                + "cumulative instead — a stepper, a quantity, a keypad — restore all "
                + "\(retryCount) taps; testFlow still records them. Tune the window with "
                + "retry_tap_interval_ms or AMOO_RETRY_TAP_INTERVAL_MS"
        )
    }

    /// Taps this close together are read as the hammering of a button that did not respond, rather
    /// than deliberate repeats a person counted out. Repeats spaced wider — a stepper being
    /// incremented, a keypad being typed on — are kept verbatim, because collapsing them would
    /// change the quantity the test asserts.
    ///
    /// **This default is not derived from data, and cannot be.** Distinguishing the two cases needs
    /// to know whether the app responded to the first tap, and nothing a session records answers
    /// that: `SessionAction.result` is `"Tapped verified element [id] label"`, built from the
    /// element tapped, so it is byte-identical whether the screen changed or not. Timing is a proxy,
    /// and the populations overlap — a PIN entered quickly beats a slow retry.
    ///
    /// So it is tunable rather than fixed, and every collapsed run reports the gaps it saw
    /// (`RetryRunObservation`) so a real value can be chosen from real recordings.
    public static let defaultRetryTapInterval: TimeInterval = 0.6

    /// Reads `AMOO_RETRY_TAP_INTERVAL_MS`, falling back to the default. A non-positive or
    /// unparseable value is ignored rather than failing a compile.
    public static func retryTapIntervalFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        guard let raw = environment["AMOO_RETRY_TAP_INTERVAL_MS"],
              let milliseconds = Double(raw), milliseconds > 0
        else { return defaultRetryTapInterval }
        return milliseconds / 1000
    }

    /// What a run of identical taps actually looked like. Reported alongside the plan so the
    /// threshold can be tuned from recordings instead of guessed at — including for runs that were
    /// *not* collapsed, which are the ones that say the threshold is too low.
    public struct RetryRunObservation: Codable, Equatable, Sendable {
        public let actionIndex: Int
        public let toolName: String
        public let selector: String
        public let tapCount: Int
        /// Seconds between consecutive taps, in order.
        public let gaps: [Double]
        public let collapsed: Bool

        public init(
            actionIndex: Int,
            toolName: String,
            selector: String,
            tapCount: Int,
            gaps: [Double],
            collapsed: Bool
        ) {
            self.actionIndex = actionIndex
            self.toolName = toolName
            self.selector = selector
            self.tapCount = tapCount
            self.gaps = gaps
            self.collapsed = collapsed
        }
    }

    /// What the retry pass concluded about one action, passed to `process` as a unit so the
    /// three values can't drift apart at the call site.
    struct RetryContext {
        /// Taps folded into this action, 1 when nothing was collapsed.
        var count: Int = 1
        var interval: TimeInterval = SessionPlanCompiler.defaultRetryTapInterval
        var gaps: [Double] = []
    }

    struct RetryAnalysis {
        var suppressed: Set<Int> = []
        var counts: [Int: Int] = [:]
        var observations: [RetryRunObservation] = []
    }

    /// Groups consecutive identical `tap_element` actions and decides which runs to collapse.
    ///
    /// The 2nd..Nth tap of a collapsed run is suppressed from `toolOperations` and mapped to the
    /// run's first index; the literal `testFlow` still replays every recorded tap. Every run of two
    /// or more is reported in `observations` whether collapsed or not, since the runs the threshold
    /// *rejects* are exactly the evidence for raising it.
    static func retryRuns(_ actions: [SessionAction], interval: TimeInterval) -> RetryAnalysis {
        var analysis = RetryAnalysis()
        var index = 0
        while index < actions.count {
            let action = actions[index]
            guard action.toolName == "tap_element" else {
                index += 1
                continue
            }
            // Group every consecutive identical tap first, then decide — measuring only the runs we
            // already intended to collapse would hide the ones arguing the threshold is wrong.
            var runEnd = index + 1
            while runEnd < actions.count,
                  actions[runEnd].toolName == "tap_element",
                  actions[runEnd].arguments == action.arguments {
                runEnd += 1
            }
            let members = Array(actions[index ..< runEnd])
            if members.count > 1 {
                let gaps = zip(members, members.dropFirst()).map {
                    $1.timestamp.timeIntervalSince($0.timestamp)
                }
                let collapsed = gaps.allSatisfy { $0 <= interval }
                if collapsed {
                    for offset in (index + 1) ..< runEnd {
                        analysis.suppressed.insert(offset)
                    }
                    analysis.counts[index] = members.count
                }
                analysis.observations.append(RetryRunObservation(
                    actionIndex: index,
                    toolName: action.toolName,
                    selector: inspectionSelector(action)?.first.map { "\($0.key)=\($0.value)" } ?? "",
                    tapCount: members.count,
                    gaps: gaps.map { ($0 * 1000).rounded() / 1000 },
                    collapsed: collapsed
                ))
            }
            index = runEnd
        }
        return analysis
    }
}
