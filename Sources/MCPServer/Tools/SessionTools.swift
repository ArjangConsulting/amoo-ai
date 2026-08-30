public enum SessionTools {
    public static let names = definitions.map(\.name)

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "start_session",
            title: "Start Session",
            description: "Boot a device, ensure the companion is running, install + launch the app, and"
                + " return a session_id used to scope subsequent calls.",
            properties: [
                "app_id": .init(
                    type: "string",
                    description: "The app's bundle identifier (iOS) or package name (Android)"
                ),
                "platform": .init(
                    type: "string",
                    description: "Target platform: 'ios' or 'android'. Defaults to 'ios'."
                ),
                "device_hint": .init(
                    type: "string",
                    description: "Optional UDID/serial or name. Auto-selects when omitted."
                ),
                "build_path": .init(
                    type: "string",
                    description: "Optional path to an .app bundle or .apk to install before launching."
                ),
                "launch_args": .init(
                    type: "string",
                    description: "Comma-separated arguments passed to the app at launch."
                ),
                "environment": .init(
                    type: "string",
                    description: "Environment variables for the session's launch, as KEY=VALUE"
                        + " pairs separated by commas — 'UITEST=1,STAGE=test' sets two. Newlines"
                        + " work as a separator too, for values that contain a comma. Needed for"
                        + " apps that only enter a test mode via an environment flag, which must"
                        + " be present at launch to take effect."
                )
            ],
            required: ["app_id"],
            outputSchema: ToolOutputSchema(
                properties: [
                    "session_id": .init(type: "string", description: "Identifier for the new session"),
                    "app_id": .init(type: "string", description: "Bundle/package id"),
                    "device_id": .init(type: "string", description: "Resolved device UDID or serial"),
                    "platform": .init(type: "string", description: "ios or android")
                ],
                required: ["session_id", "app_id", "device_id", "platform"]
            )
        ),
        ToolDefinition(
            name: "end_session",
            title: "End Session",
            description: "Terminate the app under test and release the session. Also compiles the"
                + " recorded history into replayable artifacts on disk (plan.json for"
                + " `amoo generate test --plan`, flow.json for `amoo flow`) and returns their"
                + " paths — no separate compile_session_to_plan call is needed to keep the run.",
            properties: [
                "session_id": .init(type: "string", description: "Identifier returned by start_session")
            ],
            required: ["session_id"],
            outputSchema: ToolOutputSchema(
                properties: [
                    "session_id": .init(type: "string", description: "The closed session id"),
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
        ),
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
            description: "Convert a recorded session's action history into a replayable flow (runnable"
                + " directly via `amoo flow`) and a best-effort compiledPlan (consumable by"
                + " `amoo generate test --plan`). Actions with no Studio-tool equivalent, an"
                + " approximate translation, or a redacted value are called out in `warnings`"
                + " so they can be reviewed before replay or code generation.",
            properties: [
                "session_id": .init(type: "string", description: "Identifier returned by start_session"),
                "test_name": .init(
                    type: "string",
                    description: "Name for the generated test. Defaults to 'session-<session_id>'."
                ),
                "test_description": .init(
                    type: "string",
                    description: "Description for the generated test. Defaults to a summary of the"
                        + " session's app/device."
                ),
                "retry_tap_interval_ms": .init(
                    type: "number",
                    description: "How close together identical taps must be to read as a retry loop"
                        + " and collapse into one step. Default 600ms (or"
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
