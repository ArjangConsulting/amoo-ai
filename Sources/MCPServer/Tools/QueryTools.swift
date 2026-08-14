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
                "scope": .init(
                    type: "string",
                    description: "Which process to query: 'app' (default, the app under test) or"
                        + " 'system' for system UI — permission alerts, Sign in with Apple — which"
                        + " runs outside the app and is invisible to an app-scoped query. Pass"
                        + " bundle_id instead to name a process explicitly."
                ),
                "bundle_id": .init(
                    type: "string",
                    description: "Explicit bundle/package id to query, overriding scope."
                )
            ]
        ),
        ToolDefinition(
            name: "get_view_hierarchy",
            description: "Get the full UI view hierarchy tree of the current foreground screen.",
            properties: [
                "scope": .init(
                    type: "string",
                    description: "Which process to query: 'app' (default, the app under test) or"
                        + " 'system' for system UI — permission alerts, Sign in with Apple — which"
                        + " runs outside the app and is invisible to an app-scoped query. Pass"
                        + " bundle_id instead to name a process explicitly."
                ),
                "bundle_id": .init(
                    type: "string",
                    description: "Explicit bundle/package id to query, overriding scope."
                )
            ]
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
                ),
                "scale": .init(
                    type: "number",
                    description: "Optional downscale factor in (0, 1]. 0.5 halves each dimension and"
                        + " cuts the image roughly to a quarter of the bytes — enough for reading"
                        + " layout and state, and far cheaper for a model to consume."
                        + " When omitted, the image is only returned inline."
                )
            ],
            outputSchema: ToolOutputSchema(
                properties: [
                    "byte_count": .init(type: "integer", description: "Size of the captured image in bytes"),
                    "format": .init(type: "string", description: "Image format actually captured: png or jpeg"),
                    "saved_path": .init(
                        type: "string",
                        description: "Absolute path written to, when output was provided"
                    )
                ],
                required: ["byte_count", "format"]
            )
        ),
        ToolDefinition(
            name: "is_keyboard_visible",
            description: "Check whether the on-screen keyboard is currently visible"
        ),
        ToolDefinition(
            name: "current_app",
            title: "Current App",
            description: "Bundle ID of the frontmost app — i.e. where a tap would land right now —"
                + " plus the app bound as the target. Cheaper than a screenshot for confirming"
                + " which app is in front before acting.",
            properties: [:],
            required: [],
            outputSchema: ToolOutputSchema(
                properties: [
                    "bundle_id": .init(type: "string", description: "Frontmost app, empty if unknown"),
                    "target_bundle_id": .init(type: "string", description: "Bound app under test, empty if unbound")
                ],
                required: ["bundle_id", "target_bundle_id"]
            )
        ),
        ToolDefinition(
            name: "set_target_app",
            title: "Set Target App",
            description: "Bind the app under test for subsequent commands. Pass an empty bundle_id"
                + " to unbind and follow whatever is frontmost.",
            properties: [
                "bundle_id": .init(
                    type: "string",
                    description: "Bundle identifier of the app to drive; empty unbinds."
                )
            ],
            required: []
        )
    ]
}
