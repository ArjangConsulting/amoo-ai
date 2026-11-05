// swiftlint:disable multiline_arguments
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
        let prepared = try prepareBatch(steps, sessionID: sessionID)
        for step in prepared {
            try await validateCheck(arguments: step.1)
        }
        var results: [Value] = []
        var completed = 0
        var failed = 0
        let keepGoing = boolArgument(arguments["continue_on_error"]) == true
        for (index, step) in prepared.enumerated() {
            try Task.checkCancellation()
            let result = await executeOrdered(toolName: step.0, arguments: step.1)
            results.append(batchResult(
                result,
                tool: step.0,
                index: index,
                arguments: step.1,
                full: arguments["result_mode"] == "full"
            ))
            if result.isError {
                failed += 1
                if !keepGoing {
                    break
                }
            } else {
                completed += 1
            }
        }
        let fields: [String: Value] = [
            "results": .array(results), "completed": .int(completed), "failed": .int(failed),
            "attempted": .int(results.count), "unattempted": .int(steps.count - results.count),
            "dispatch_is_proof": .bool(false)
        ]
        return ToolResult(
            content: "Batch: \(completed) succeeded, \(failed) failed, \(steps.count - results.count) unattempted.",
            isError: failed > 0, structuredContent: .object(fields)
        )
    }

    private func prepareBatch(_ steps: [BatchStep], sessionID: String) throws -> [(String, [String: String])] {
        let allowed: Set = [
            "tap", "tap_element", "double_tap", "long_press", "type_text", "set_text", "fill_field",
            "clear_text", "swipe", "swipe_in_direction", "scroll", "drag", "pinch", "press_back",
            "assert_visible", "assert_absent", "assert_enabled", "assert_value", "assert_selected", "assert_checked",
            "assert_state_description", "take_screenshot",
            "assert_screen_changed"
        ]
        return try steps.map { step -> (String, [String: String]) in
            guard allowed.contains(step.tool), step.arguments["session_id"] == nil else {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "Unsupported batch step or session override."
                )
            }
            var values = step.arguments.mapValues { $0.stringValue ?? $0.description }
            if step.tool == "take_screenshot" {
                guard let output = values["output"], !output.isEmpty,
                      values["return_image"]?.lowercased() == "false"
                else {
                    throw ToolExecutionError(
                        code: "invalid_argument",
                        message: "Batch take_screenshot steps require output and return_image=false."
                    )
                }
            }
            values["session_id"] = sessionID
            _ = try ToolRequest(name: step.tool, arguments: values)
            for (key, maximum) in ["timeout_ms": 10000, "duration_ms": 3000] {
                if let raw = values[key], Int(raw).map({ (0 ... maximum).contains($0) }) != true {
                    throw ToolRequest.invalidArgument(key, example: "\(key)=1000")
                }
            }
            return (step.tool, values)
        }
    }

    private func batchResult(
        _ result: ToolResult, tool: String, index: Int, arguments: [String: String], full: Bool
    ) -> Value {
        var row: [String: Value] = [
            "index": .int(index), "tool": .string(tool), "success": .bool(!result.isError),
            "summary": .string(String(result.content.prefix(400)))
        ]
        let proofKeys: Set = [
            "outcome_status", "postcondition_verified", "capture_suspect", "capture_analysis", "viewport",
            "screen_state", "foreground_app_id", "target_app_id", "available_controls", "selector_hint",
            "passed", "failure_kind", "code", "dispatch_status", "last_observation_status", "saved_path",
            "byte_count", "width_pixels", "height_pixels", "scale", "semantic_readiness", "verified"
        ]
        if let fields = result.structuredContent?.objectValue {
            row["structured"] = .object(full
                ? fields : fields.filter { proofKeys.contains($0.key) })
        }
        if let check = arguments["check_id"] {
            row["check_id"] = .string(check)
        }
        if full {
            row["content"] = .string(result.content)
        }
        return .object(row)
    }
}

// swiftlint:enable multiline_arguments
