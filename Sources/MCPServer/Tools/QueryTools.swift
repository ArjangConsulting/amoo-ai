public enum QueryTools {
    public static let names = definitions.map(\.name)

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "find_elements",
            description: "Find UI elements matching a selector. Returns matching element IDs and labels.",
            properties: [
                "id": .init(type: "string", description: "Accessibility identifier to match"),
                "label": .init(type: "string", description: "Accessibility label to match"),
                "contains_text": .init(type: "string", description: "Partial text match"),
                "description": .init(type: "string", description: "Natural language description for AI matching")
            ]
        ),
        ToolDefinition(
            name: "get_view_hierarchy",
            description: "Get the full UI view hierarchy tree of the current foreground screen."
        ),
        ToolDefinition(
            name: "get_screen_context",
            description: "Get an AI-optimized summary of the current screen state"
        ),
        ToolDefinition(
            name: "take_screenshot",
            description: "Capture a screenshot of the current screen."
                + " Returns the image as an MCP image content block, and optionally writes it to disk.",
            properties: [
                "format": .init(
                    type: "string",
                    description: "Image format: png or jpeg. Defaults to png. Best-effort —"
                        + " some drivers always capture png; check the format field in the result."
                ),
                "output": .init(
                    type: "string",
                    description: "Optional file path to also save the screenshot to (~ is expanded)."
                        + " When omitted, the image is only returned inline."
                )
            ],
            outputSchema: ToolOutputSchema(
                properties: [
                    "byte_count": .init(type: "integer", description: "Size of the captured image in bytes"),
                    "format": .init(type: "string", description: "Image format actually captured: png or jpeg"),
                    "saved_path": .init(type: "string", description: "Absolute path written to, when output was provided")
                ],
                required: ["byte_count", "format"]
            )
        ),
        ToolDefinition(
            name: "is_keyboard_visible",
            description: "Check whether the on-screen keyboard is currently visible"
        )
    ]
}
