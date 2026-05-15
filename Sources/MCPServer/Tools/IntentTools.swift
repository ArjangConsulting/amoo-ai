public enum IntentTools {
    public static let names = definitions.map(\.name)

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "navigate_to",
            title: "Navigate To",
            description: "Best-effort navigation: matches an element by description and taps it,"
                + " waiting briefly for the screen to change. Returns the new screen context.",
            properties: [
                "description": .init(
                    type: "string",
                    description: "Natural-language description of the screen or element to navigate to"
                ),
                "session_id": .init(
                    type: "string",
                    description: "Optional session id; defaults to the server's default driver"
                ),
                "timeout_ms": .init(
                    type: "string",
                    description: "Max time to wait for the screen to change after tapping (default 3000)"
                )
            ],
            required: ["description"],
            outputSchema: ToolOutputSchema(
                properties: [
                    "navigated": .init(type: "boolean", description: "Whether a tap was performed"),
                    "screen_summary": .init(type: "string", description: "Current screen summary"),
                    "element_id": .init(type: "string", description: "Tapped element id, when applicable"),
                    "element_label": .init(type: "string", description: "Tapped element label, when applicable"),
                    "matched_current_screen": .init(type: "boolean", description: "True when already on target"),
                    "reason": .init(type: "string", description: "Failure reason when navigated is false")
                ],
                required: ["navigated", "screen_summary"]
            )
        ),
        ToolDefinition(
            name: "fill_field",
            title: "Fill Field",
            description: "Find a text field by description and set its value. Uses the driver's setText for a"
                + " single round-trip; never echoes the value in logs.",
            properties: [
                "field_description": .init(
                    type: "string",
                    description: "Natural-language description of the field (e.g. 'Email')"
                ),
                "value": .init(type: "string", description: "Value to type"),
                "session_id": .init(
                    type: "string",
                    description: "Optional session id; defaults to the server's default driver"
                )
            ],
            required: ["field_description", "value"],
            outputSchema: ToolOutputSchema(
                properties: [
                    "field_description": .init(type: "string", description: "Field that was filled"),
                    "value_length": .init(type: "integer", description: "Length of the value typed")
                ],
                required: ["field_description", "value_length"]
            )
        ),
        ToolDefinition(
            name: "assert_visible",
            title: "Assert Visible",
            description: "Poll for an element matching the description until it appears or the timeout expires."
                + " Returns a pass/fail result with the matched element details.",
            properties: [
                "description": .init(
                    type: "string",
                    description: "Natural-language description of the element to find"
                ),
                "session_id": .init(
                    type: "string",
                    description: "Optional session id; defaults to the server's default driver"
                ),
                "timeout_ms": .init(
                    type: "string",
                    description: "Max time to wait for the element to appear (default 5000)"
                )
            ],
            required: ["description"],
            outputSchema: ToolOutputSchema(
                properties: [
                    "passed": .init(type: "boolean", description: "Whether the element appeared in time"),
                    "element_id": .init(type: "string", description: "Matched element id"),
                    "element_label": .init(type: "string", description: "Matched element label"),
                    "element_type": .init(type: "string", description: "Matched element type"),
                    "screen_summary": .init(type: "string", description: "Current screen summary"),
                    "query": .init(type: "string", description: "Echoes the original query when not found"),
                    "query_lowercased": .init(type: "string", description: "Lower-cased query when not found")
                ],
                required: ["passed", "screen_summary"]
            )
        )
    ]
}
