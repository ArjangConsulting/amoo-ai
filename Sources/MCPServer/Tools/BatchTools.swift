public enum BatchTools {
    public static let definitions = [ToolDefinition(
        name: "run_steps",
        description: "Run 1–20 known actions/assertions in one managed session. Stops on first failure;"
            + " records each step separately. No nested batches or lifecycle calls. No rollback.",
        properties: [
            "session_id": .init(type: "string", description: "Active managed session"),
            "steps": .init(
                type: "array",
                description: "Ordered tool and arguments objects. Per-step timeout at most 10000 ms.",
                items: .object(properties: [
                    "tool": .init(type: "string", description: "Deterministic action/assertion tool name"),
                    "arguments": .init(type: "object", description: "Normal arguments; session_id is inherited")
                ], required: ["tool", "arguments"])
            )
        ],
        required: ["session_id", "steps"]
    )]
}
