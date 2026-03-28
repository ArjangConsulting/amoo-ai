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
                "description": .init(type: "string", description: "Natural language description for AI matching"),
            ]
        ),
        ToolDefinition(
            name: "get_view_hierarchy",
            description: "Get the full UI view hierarchy tree of the current screen. Uses the last launched app by default.",
            properties: [
                "app_id": .init(type: "string", description: "Bundle ID of the app to inspect. Omit to use the last launched app."),
            ]
        ),
        ToolDefinition(
            name: "get_screen_context",
            description: "Get an AI-optimized summary of the current screen state"
        ),
        ToolDefinition(
            name: "take_screenshot",
            description: "Capture a screenshot of the current screen",
            properties: [
                "format": .init(type: "string", description: "Image format: png or jpeg. Defaults to png."),
                "output": .init(type: "string", description: "Optional file path to save the screenshot. Defaults to screenshot_<timestamp>.png in the current directory."),
            ]
        ),
        ToolDefinition(
            name: "is_keyboard_visible",
            description: "Check whether the on-screen keyboard is currently visible"
        ),
    ]
}
