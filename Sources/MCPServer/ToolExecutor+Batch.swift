import Foundation
import MCP

private struct BatchStep: Decodable {
    let tool: String
    let arguments: [String: Value]
}

extension DriverToolExecutor {
    func executeBatch(arguments: [String: String]) async throws -> ToolResult {
        guard let sessionID = arguments["session_id"], let source = arguments["steps"], source.utf8.count <= 65536,
              let steps = try? JSONDecoder().decode([BatchStep].self, from: Data(source.utf8)),
              (1 ... 20).contains(steps.count) else {
            throw ToolExecutionError(code: "invalid_argument", message: "run_steps requires a session and 1–20 steps.")
        }
        let allowed: Set = [
            "tap", "tap_element", "double_tap", "long_press", "type_text", "set_text", "fill_field",
            "clear_text", "swipe", "swipe_in_direction", "scroll", "press_back",
            "assert_visible", "assert_absent", "assert_enabled", "assert_value", "assert_screen_changed"
        ]
        let prepared = try steps.map { step -> (String, [String: String]) in
            guard allowed.contains(step.tool), step.arguments["session_id"] == nil else {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "Unsupported batch step or session override."
                )
            }
            var values = step.arguments.mapValues { $0.stringValue ?? $0.description }
            values["session_id"] = sessionID
            _ = try ToolRequest(name: step.tool, arguments: values)
            _ = try QueryPage.integer(values["timeout_ms"], fallback: 0, range: 0 ... 10000)
            _ = try QueryPage.integer(values["duration_ms"], fallback: 0, range: 0 ... 3000)
            return (step.tool, values)
        }
        var results: [Value] = []
        for (index, step) in prepared.enumerated() {
            try Task.checkCancellation()
            let result = await executeOrdered(toolName: step.0, arguments: step.1)
            results.append(.object([
                "index": .int(index), "tool": .string(step.0), "success": .bool(!result.isError),
                "summary": .string(String(result.content.prefix(400)))
            ]))
            if result.isError {
                return ToolResult(
                    content: "Batch stopped at step \(index + 1) of \(steps.count): \(result.content.prefix(400))",
                    isError: true,
                    structuredContent: .object(["results": .array(results), "completed": .int(index)])
                )
            }
        }
        return .success(
            "Completed \(steps.count) steps.",
            structuredContent: .object(["results": .array(results), "completed": .int(steps.count)])
        )
    }
}
