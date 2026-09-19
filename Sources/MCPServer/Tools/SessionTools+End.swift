extension SessionTools {
    static var endSessionDefinition: ToolDefinition {
        ToolDefinition(
            name: "end_session",
            title: "End Session",
            description: "Terminate the app under test and release the session. Also compiles the"
                + " recorded history into replayable artifacts on disk (plan.json for"
                + " `amoo generate test --plan`, flow.json for `amoo flow`) and returns their"
                + " paths — no separate compile_session_to_plan call is needed to keep the run."
                +
                " If a device call stalls, use force=true to cancel queued work and close without terminating the app.",
            properties: [
                "session_id": .init(type: "string", description: "Identifier returned by start_session"),
                "force": .init(
                    type: "boolean",
                    description: "Cancel device work and skip app termination. Defaults to false."
                )
            ],
            required: ["session_id"],
            outputSchema: ToolOutputSchema(
                properties: [
                    "session_id": .init(type: "string", description: "The closed session id"),
                    "artifact_error": .init(type: "string", description: "Artifact generation failure"),
                    "forced": .init(type: "boolean", description: "Closed without waiting for app termination"),
                    "ended_at": .init(type: "string", description: "ISO-8601 close timestamp"),
                    "action_count": .init(type: "integer", description: "Number of recorded actions"),
                    "plan_path": .init(
                        type: "string",
                        description: "Path to the auto-written StudioAuthoredTest JSON, when a store is configured"
                    ),
                    "flow_path": .init(
                        type: "string",
                        description: "Path to the auto-written replayable flow JSON, when a store is configured"
                    ),
                    "warning_count": .init(
                        type: "integer",
                        description: "Actions the compiler could not translate exactly"
                    )
                ],
                required: ["session_id", "ended_at", "action_count"]
            )
        )
    }
}
