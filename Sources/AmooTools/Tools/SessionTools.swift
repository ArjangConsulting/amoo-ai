public enum SessionTools {
    public static let names = definitions.map(\.name)

    public static let definitions: [ToolDefinition] = [
        startSessionDefinition,
        ToolDefinition(
            name: "session_startup_status",
            title: "Session Startup Status",
            description: "Poll concurrent or recent start_session operations for stages, elapsed time, and outcome."
                + " Safe to call while start_session is pending; do not start a duplicate session."
        ),
        endSessionDefinition,
        ToolDefinition(
            name: "list_sessions",
            title: "List Sessions",
            description: "List all active and closed sessions known to this server.",
            outputSchema: ToolOutputSchema(
                properties: [
                    "sessions": .init(
                        type: "array",
                        description: "Session summaries",
                        items: .object(
                            properties: [
                                "session_id": .init(type: "string", description: "Session id"),
                                "app_id": .init(type: "string", description: "Bundle/package id"),
                                "device_id": .init(type: "string", description: "Device id"),
                                "platform": .init(type: "string", description: "ios or android"),
                                "started_at": .init(type: "string", description: "ISO-8601 start time"),
                                "action_count": .init(type: "integer", description: "Recorded action count"),
                                "is_active": .init(type: "boolean", description: "Whether the session is still open")
                            ],
                            required: [
                                "session_id",
                                "app_id",
                                "device_id",
                                "platform",
                                "started_at",
                                "action_count",
                                "is_active"
                            ]
                        )
                    )
                ],
                required: ["sessions"]
            )
        ),
        ToolDefinition(
            name: "get_session_report",
            title: "Get Session Report",
            description: "Return the full action history and summary for a session.",
            properties: [
                "session_id": .init(type: "string", description: "Identifier returned by start_session")
            ],
            required: ["session_id"],
            outputSchema: ToolOutputSchema(
                properties: [
                    "sessionID": .init(type: "string", description: "Session id"),
                    "appID": .init(type: "string", description: "Bundle/package id"),
                    "deviceID": .init(type: "string", description: "Device id"),
                    "platform": .init(type: "string", description: "ios or android"),
                    "startedAt": .init(type: "string", description: "ISO-8601 start"),
                    "endedAt": .init(type: "string", description: "ISO-8601 end, when closed"),
                    "durationSeconds": .init(type: "number", description: "Elapsed seconds"),
                    "actionCount": .init(type: "integer", description: "Number of actions recorded"),
                    "errorCount": .init(type: "integer", description: "Number of failed actions"),
                    "isActive": .init(type: "boolean", description: "Still active?"),
                    "actions": .init(
                        type: "array",
                        description: "Recorded actions",
                        items: .object(
                            properties: [
                                "timestamp": .init(type: "string", description: "ISO-8601 timestamp"),
                                "toolName": .init(type: "string", description: "MCP tool name"),
                                "result": .init(type: "string", description: "Result text"),
                                "isError": .init(type: "boolean", description: "Whether this call failed")
                            ],
                            required: ["timestamp", "toolName", "result", "isError"]
                        )
                    )
                ],
                required: [
                    "sessionID",
                    "appID",
                    "deviceID",
                    "platform",
                    "startedAt",
                    "durationSeconds",
                    "actionCount",
                    "errorCount",
                    "isActive",
                    "actions"
                ]
            )
        ),
        ToolDefinition(
            name: "compile_session_to_plan",
            title: "Compile Session To Plan",
            description: "OPTIONAL preview. Convert a recorded session's action history into a"
                + " replayable flow (runnable directly via `amoo flow`) and a best-effort"
                + " compiledPlan (consumable by `amoo generate test --plan`), without ending the"
                + " session. The canonical workflow does not need this call: `end_session` compiles"
                + " and writes the same plan.json/flow.json on close, and calling this first does"
                + " not change that final plan. Use it only to inspect the plan mid-session."
                + " Actions with no Studio-tool equivalent, an approximate translation, or a"
                + " redacted value are called out in `warnings` for review before code generation.",
            properties: [
                "session_id": .init(type: "string", description: "Identifier returned by start_session"),
                "fresh_install": .init(
                    type: "boolean",
                    description: "Remove the existing app and local data before installing. Requires build_path."
                        + " Does not clear external stores such as iOS Keychain or server data. Default false."
                ),
                "test_name": .init(
                    type: "string",
                    description: "Name for the generated test. Overrides the session name; otherwise a semantic"
                        + " name is inferred from the recorded flow."
                ),
                "test_description": .init(
                    type: "string",
                    description: "Description for the generated test. Defaults to a summary of the"
                        + " session's app/device."
                ),
                "context_path": .init(
                    type: "string",
                    description: "Optional path to test-context JSON or amoo.md with a fenced amoo-context"
                        + " JSON block (imports, baseClass,"
                        + " appFactory, harnessLaunchesApp, helpers, selectorExpressions). Folded into"
                        + " the plan's testContext and persisted with the session, so a later"
                        + " end_session recompile and `amoo generate test` reuse it without a"
                        + " CLI-only --context override."
                ),
                "context_json": .init(
                    type: "string",
                    description: "Inline test-context JSON, an alternative to context_path."
                ),
                "retry_tap_interval_ms": .init(
                    type: "number",
                    description: "How close together identical taps must be to read as a retry loop"
                        + " and collapse into one step. Default 300ms — deliberately below the"
                        + " ~450ms companion round-trip, so agent-issued taps are never collapsed"
                        + " on transport latency alone. (or"
                        + " AMOO_RETRY_TAP_INTERVAL_MS). Raise it if a hammered button was kept as"
                        + " N steps; lower it if a deliberate repeat — a stepper, a quantity, a"
                        + " keypad — was wrongly collapsed. `retryRunObservations` in the output"
                        + " reports every repeated-tap run with its gaps, collapsed or not, which"
                        + " is how you pick a value for this app rather than guessing."
                )
            ],
            required: ["session_id"],
            outputSchema: ToolOutputSchema(
                properties: [
                    "testFlow": .init(
                        type: "object",
                        description: "TestFlow-shaped JSON ({platform, device_id, steps}) runnable via `amoo flow`"
                    ),
                    "studioTest": .init(
                        type: "object",
                        description: "StudioAuthoredTest JSON consumable by `amoo generate test --plan`"
                    ),
                    "warnings": .init(
                        type: "array",
                        description: "Actions excluded or approximately translated in studioTest",
                        items: .object(
                            properties: [
                                "actionIndex": .init(
                                    type: "integer",
                                    description: "Index into the session's action list"
                                ),
                                "toolName": .init(type: "string", description: "Recorded MCP tool name"),
                                "reason": .init(type: "string", description: "Why this action needs review")
                            ],
                            required: ["actionIndex", "toolName", "reason"]
                        )
                    ),
                    "retryRunObservations": .init(
                        type: "array",
                        description: "Every run of 2+ consecutive identical taps, collapsed or not,"
                            + " with the gaps that decided it. The tuning evidence for"
                            + " retry_tap_interval_ms.",
                        items: .object(
                            properties: [
                                "actionIndex": .init(
                                    type: "integer",
                                    description: "Index of the run's first tap"
                                ),
                                "selector": .init(type: "string", description: "The tapped element"),
                                "tapCount": .init(type: "integer", description: "Taps in the run"),
                                "gaps": .init(
                                    type: "array",
                                    description: "Seconds between consecutive taps, in order"
                                ),
                                "collapsed": .init(
                                    type: "boolean",
                                    description: "Whether the run was folded into a single step"
                                )
                            ],
                            required: ["actionIndex", "tapCount", "gaps", "collapsed"]
                        )
                    ),
                    "retryTapIntervalSeconds": .init(
                        type: "number",
                        description: "The retry window this compile used, so the observations are"
                            + " interpretable on their own"
                    )
                ],
                required: ["testFlow", "studioTest", "warnings"]
            )
        )
    ]
}
