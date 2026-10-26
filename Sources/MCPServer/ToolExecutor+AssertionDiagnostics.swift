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
                ? "Assertion mismatch after \(milliseconds)ms; see last observed state."
                : "Assertion could not complete its observation after \(milliseconds)ms: "
                + "\(observationError ?? "unknown")"
                + " Companion/device health is unconfirmed; app postcondition remains unverified.",
            isError: true, structuredContent: .object(fields)
        )
    }
}

// swiftlint:enable multiline_arguments
