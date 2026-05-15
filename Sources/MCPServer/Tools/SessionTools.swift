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
            description: "Terminate the app under test and release the session.",
            properties: [
                "session_id": .init(type: "string", description: "Identifier returned by start_session")
            ],
            required: ["session_id"],
            outputSchema: ToolOutputSchema(
                properties: [
                    "session_id": .init(type: "string", description: "The closed session id"),
                    "ended_at": .init(type: "string", description: "ISO-8601 close timestamp"),
                    "action_count": .init(type: "integer", description: "Number of recorded actions")
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
                            required: ["session_id", "app_id", "device_id", "platform", "started_at", "action_count", "is_active"]
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
                required: ["sessionID", "appID", "deviceID", "platform", "startedAt", "durationSeconds",
                          "actionCount", "errorCount", "isActive", "actions"]
            )
        )
    ]
}
