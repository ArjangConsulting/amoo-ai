import AmooCore
import MCP

/// Stable machine-readable failure, without embedding device content or user input.
struct ToolExecutionError: Error {
    let code: String
    let message: String
    /// Extra structured fields merged into the result alongside `code`/`message`/`retryable`.
    var extra: [String: Value] = [:]

    var result: ToolResult {
        var object: [String: Value] = [
            "code": .string(code), "message": .string(message), "retryable": .bool(false)
        ]
        for (key, value) in extra {
            object[key] = value
        }
        return ToolResult(content: message, isError: true, structuredContent: .object(object))
    }
}

extension DriverToolExecutor {
    /// Mutations and single-element assertions require an unambiguous selector.
    ///
    /// The naive "matched N elements" message pushed callers straight to raw coordinate taps —
    /// the exact fragile path the driving skill tells them to avoid — because it gave them
    /// nothing to disambiguate with. `find_elements` already resolved id/type/frame for every
    /// candidate to get here, so surface it: a real id lets the caller retry precisely, and a
    /// frame lets it tap a specific, already-computed point instead of eyeballing a screenshot.
    func uniqueElement(_ elements: [ElementInfo]) throws -> ElementInfo? {
        guard elements.count <= 1 else {
            let candidates = Array(elements.prefix(8))
            let summary = candidates.map { element -> String in
                var parts = [element.id.isEmpty ? "id=(none)" : "id=\(element.id)"]
                if let type = element.type {
                    parts.append("type=\(type.rawValue)")
                }
                if let point = element.hitPoint ?? element.frame?.centre {
                    parts.append("at=(\(Int(point.x)),\(Int(point.y)))")
                }
                return "[" + parts.joined(separator: " ") + "]"
            }.joined(separator: ", ")
            throw ToolExecutionError(
                code: "ambiguous_selector",
                message: "Selector matched \(elements.count) elements: \(summary). Retry with the"
                    + " id of the one you want, or scope with parent_id. If none has an id, tap its"
                    + " listed point directly rather than guessing coordinates from a screenshot.",
                extra: ["candidates": .array(candidates.map(elementFields))]
            )
        }
        return elements.first
    }
}
