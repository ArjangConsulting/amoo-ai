/// Companion lifecycle tools, exposed only when the server runs with session management
/// (`amoo mcp serve`). They let an agent move the minutes-long first-start build off the
/// critical path instead of paying it inside the first `start_session`.
public enum CompanionTools {
    public static let names = definitions.map(\.name)

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "companion_warm",
            title: "Warm Companion",
            description: "Start building + installing the companion test bundle in the background and"
                + " return immediately. The build is the slow (minutes-long) part of the first"
                + " start_session; running this as step 0 moves that wait off the critical path."
                + " Poll companion_status for progress. Requires `amoo mcp serve`.",
            properties: [
                "platform": .init(type: "string", description: "'ios' or 'android'. Defaults to 'ios'."),
                "device_hint": .init(
                    type: "string",
                    description: "Optional UDID/serial or name; auto-selects when omitted."
                ),
                "app_id": .init(type: "string", description: "Optional bundle id to bind as the gesture target.")
            ],
            outputSchema: ToolOutputSchema(
                properties: ["status": .init(type: "string", description: "Human-readable acknowledgement")],
                required: ["status"]
            )
        ),
        ToolDefinition(
            name: "companion_status",
            title: "Companion Status",
            description: "Non-blocking one-line report of companion readiness: ready (listening),"
                + " built (bundle ready, not launched), building / launching (a warm is in"
                + " progress), failed, or not_started.",
            properties: [
                "platform": .init(type: "string", description: "'ios' or 'android'. Defaults to 'ios'."),
                "device_hint": .init(type: "string", description: "Optional UDID/serial or name.")
            ],
            outputSchema: ToolOutputSchema(
                properties: ["status": .init(type: "string", description: "One-line readiness report")],
                required: ["status"]
            )
        )
    ]
}
