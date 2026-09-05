import AmooCore
import MCP

/// Stable machine-readable failure, without embedding device content or user input.
struct ToolExecutionError: Error {
    let code: String
    let message: String

    var result: ToolResult {
        ToolResult(
            content: message,
            isError: true,
            structuredContent: .object([
                "code": .string(code), "message": .string(message), "retryable": .bool(false)
            ])
        )
    }
}

extension DriverToolExecutor {
    /// Mutations and single-element assertions require an unambiguous selector.
    func uniqueElement(_ elements: [ElementInfo]) throws -> ElementInfo? {
        guard elements.count <= 1 else {
            throw ToolExecutionError(
                code: "ambiguous_selector",
                message: "Selector matched \(elements.count) elements. Use a unique identifier or parent selector."
            )
        }
        return elements.first
    }
}
