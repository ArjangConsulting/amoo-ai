// swiftlint:disable multiline_arguments
import AmooCore
import MCP

extension DriverToolExecutor {
    // swiftlint:disable:next function_parameter_count
    func assertionFailure(
        kind: ElementAssertionKind,
        arguments: [String: String],
        lastMatch: ElementInfo?,
        reads: Int,
        started: ContinuousClock.Instant,
        observationError: String?
    ) -> ToolResult {
        let duration = started.duration(to: .now).components
        let milliseconds = Int(duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000)
        var fields: [String: Value] = [
            "passed": .bool(false),
            "failure_kind": .string(observationError == nil ? "assertion_mismatch" : "observation_failed"),
            "property": .string(kind.rawValue),
            "elapsed_ms": .int(milliseconds),
            "completed_observations": .int(reads),
            "dispatch_status": .string("not_applicable"),
            "companion_health": .string(observationError == nil ? "responded" : "unconfirmed"),
            "device_health": .string("unconfirmed"),
            "tree_completeness": .string("unknown"),
            "last_observation_status": .string(reads == 0 ? "unavailable" : "last_completed_query")
        ]
        let selectorKeys = ["id", "label", "contains_text", "parent_id", "index", "first"]
        fields["selector"] = .object(arguments.filter { selectorKeys.contains($0.key) }.mapValues(Value.string))
        if let expected = arguments["expected"] ?? arguments["contains"] {
            fields["expected"] = .string(expected)
            fields["comparison"] = .string(arguments["contains"] == nil ? "equals" : "contains")
        }
        if let lastMatch {
            fields["last_observed"] = .object([
                "visible": .bool(lastMatch.isVisible), "enabled": .bool(lastMatch.isEnabled),
                "value": lastMatch.isSecureTextEntry ? .string("redacted") : lastMatch.value.map(Value.string) ?? .null
            ])
        } else {
            fields["last_observed"] = .string(reads == 0 ? "unavailable" : "no_match")
        }
        if let observationError {
            fields["observation_error"] = .string(observationError)
        }
        return ToolResult(
            content: observationError == nil
                ? "Assertion mismatch after \(milliseconds)ms: expected \(kind.rawValue)\(Self.expectation(arguments));"
                + " last observed \(Self.observedSummary(lastMatch, reads: reads))."
                : "Assertion could not complete its observation after \(milliseconds)ms: "
                + "\(observationError ?? "unknown")"
                + " Companion/device health is unconfirmed; app postcondition remains unverified.",
            isError: true, structuredContent: .object(fields)
        )
    }
}

extension DriverToolExecutor {
    /// ` "<expected>"` or ` containing "<expected>"`, for a value assertion; empty otherwise.
    static func expectation(_ arguments: [String: String]) -> String {
        if let contains = arguments["contains"] {
            return " containing \"\(contains)\""
        }
        return arguments["expected"].map { " \"\($0)\"" } ?? ""
    }

    /// What the last completed read saw, in one line, so a failed flow step needs no follow-up
    /// query to explain itself.
    static func observedSummary(_ match: ElementInfo?, reads: Int) -> String {
        guard let match else {
            return reads == 0 ? "nothing (no read completed)" : "no element matching the selector"
        }
        var parts = ["[\(match.id)] \(match.label)", "visible=\(match.isVisible)", "enabled=\(match.isEnabled)"]
        if let value = match.value {
            parts.append("value=" + (match.isSecureTextEntry ? "redacted" : "\"\(value)\""))
        }
        if let selected = match.isSelected {
            parts.append("selected=\(selected)")
        }
        return parts.joined(separator: " ")
    }
}

// swiftlint:enable multiline_arguments
