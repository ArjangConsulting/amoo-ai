import AmooCore
import Foundation
import MCP

/// `assert_selected`: the element exists and its selected state equals `expected`.
///
/// This is the only way to check selection. `assert_visible` and `assert_enabled` cannot observe it
/// (an unselected day is as visible and enabled as a selected one), and `assert_value` reads the
/// accessibility *value*, which a control that communicates selection through the selected trait
/// leaves empty. A platform that does not report a selected state is refused outright; falling back
/// to one of those weaker checks would pass for the wrong reason.
extension DriverToolExecutor {
    /// Floor on the first query, so an assertion with a tiny `timeout_ms` still asks the device
    /// once and can report what it saw instead of expiring before it looked.
    private static let firstQueryBudget: Swift.Duration = .seconds(2)

    /// What the last completed query concluded.
    private enum SelectionObservation: Equatable {
        /// The query has not completed, for example because the deadline passed first.
        case none
        case notFound
        case selected(Bool, id: String, label: String)

        var name: String {
            switch self {
            case .none: "no_observation"
            case .notFound: "not_found"
            case let .selected(isSelected, _, _): isSelected ? "selected" : "unselected"
            }
        }
    }

    /// Parses `expected`, which defaults to `true`. Anything but `true`/`false` is rejected rather
    /// than guessed at, because a misread negative expectation would assert the opposite.
    static func parseExpectedSelection(_ raw: String?) throws -> Bool {
        guard let raw else { return true }
        switch raw.lowercased() {
        case "true": return true
        case "false": return false
        default:
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "expected must be true or false, got '\(raw)'."
            )
        }
    }

    func executeAssertSelected(
        arguments: [String: String],
        driver: any PlatformDriver
    ) async throws -> ToolResult {
        guard let selector = try preferredSelector(arguments: arguments, includeDescription: true) else {
            return .error("An element selector is required: id, label, contains_text, or description")
        }
        let expected = try Self.parseExpectedSelection(arguments["expected"])
        let timeoutMS = arguments["timeout_ms"].flatMap(Int.init) ?? 5000
        let deadline = ContinuousClock.now + .milliseconds(max(1, timeoutMS))
        let appID = queryScopeAppID(arguments: arguments, driver: driver)
        let pick = try ElementPick.parse(arguments)
        let constraints = Self.describeConstraints(selector)

        var observation = SelectionObservation.none
        var firstQuery = true
        repeat {
            if Task.isCancelled {
                return ToolExecutionError(code: "cancelled", message: "Operation cancelled.").result
            }
            let readDeadline = firstQuery
                ? max(deadline, ContinuousClock.now + Self.firstQueryBudget)
                : deadline
            firstQuery = false
            do {
                let match = try await OperationDeadline.read(until: readDeadline) {
                    try await self.resolveElement(
                        selector: selector, driver: driver, appID: appID, pick: pick, missingIsNil: true
                    )
                }
                guard let match else {
                    observation = .notFound
                    try? await Task.sleep(until: min(deadline, .now + .milliseconds(200)), clock: .continuous)
                    continue
                }
                guard let isSelected = match.isSelected else {
                    return ToolExecutionError(
                        code: "selected_state_unsupported",
                        message: "assert_selected is unsupported here: the device did not report a selected state"
                            + " for [\(match.id)] \(match.label) (selector: \(constraints)). Visibility, enabled"
                            + " state and value are not substitutes for it.",
                        extra: ["selector": .string(constraints), "expected": .bool(expected)]
                    ).result
                }
                observation = .selected(isSelected, id: match.id, label: match.label)
                if isSelected == expected {
                    return .success(
                        "Element is \(expected ? "selected" : "unselected"): [\(match.id)] \(match.label)",
                        structuredContent: .object([
                            "passed": .bool(true),
                            "element_id": .string(match.id),
                            "element_label": .string(match.label),
                            "expected": .bool(expected),
                            "observed": .string(observation.name)
                        ])
                    )
                }
            } catch is OperationDeadline.DeadlineExceeded {
                break
            }
            try? await Task.sleep(until: min(deadline, .now + .milliseconds(200)), clock: .continuous)
        } while ContinuousClock.now < deadline

        return selectedFailure(
            expected: expected, observation: observation, constraints: constraints, timeoutMS: timeoutMS
        )
    }

    private func selectedFailure(
        expected: Bool,
        observation: SelectionObservation,
        constraints: String,
        timeoutMS: Int
    ) -> ToolResult {
        let wanted = "selected=\(expected)"
        var fields: [String: Value] = [
            "passed": .bool(false),
            "selector": .string(constraints),
            "expected": .bool(expected),
            "observed": .string(observation.name),
            "resolution_failed": .bool(observation == .notFound || observation == .none),
            "timeout_ms": .int(timeoutMS)
        ]
        let detail: String
        switch observation {
        case .none:
            detail = "the device could not be queried before the deadline, so no state was observed"
        case .notFound:
            detail = "no element matched, so selection was not checked (the element must exist)"
        case let .selected(isSelected, id, label):
            fields["element_id"] = .string(id)
            fields["element_label"] = .string(label)
            detail = "observed selected=\(isSelected) on [\(id)] \(label)"
        }
        return ToolResult(
            content: "assert_selected failed after \(timeoutMS)ms: expected \(wanted); \(detail)."
                + " Selector: \(constraints).",
            isError: true,
            structuredContent: .object(fields)
        )
    }
}
