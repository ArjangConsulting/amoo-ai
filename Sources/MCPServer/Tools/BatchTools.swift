// swiftlint:disable multiline_arguments
public enum BatchTools {
    public static let definitions = [ToolDefinition(
        name: "run_steps",
        description: "Run 1–20 known actions, assertions, or screenshot observations in one managed session."
            + " Stops on first failure and returns compact step summaries. For transient UI, put"
            + " take_screenshot immediately after the action with output, return_image=false, and"
            + " settle_timeout_ms=0. Set check_effect=false on a triggering tap_element to skip post-tap"
            + " hierarchy reads; a coordinate tap from fresh geometry also avoids foreground-app observation."
            + " Capture before asserting the eventual outcome. Device latency still applies."
            + " No nested batches or lifecycle calls. No rollback.",
        properties: [
            "session_id": .init(type: "string", description: "Active managed session"),
            "continue_on_error": .init(
                type: "boolean", description: "Continue independent checks after errors; default false"
            ),
            "result_mode": .init(
                type: "string", description: "compact (default) retains proof and evidence paths; full retains details",
                values: ["compact", "full"]
            ),
            "steps": .init(
                type: "array",
                description: "Ordered tool and arguments objects. Per-step timeout at most 10000 ms."
                    + " Screenshot steps must save to output; batch results do not return images inline.",
                items: .object(properties: [
                    "tool": .init(type: "string", description: "Deterministic action/assertion tool name"),
                    "arguments": .init(type: "object", description: "Normal arguments; session_id is inherited")
                ], required: ["tool", "arguments"])
            )
        ],
        required: ["session_id", "steps"]
    )]
}

// swiftlint:enable multiline_arguments
