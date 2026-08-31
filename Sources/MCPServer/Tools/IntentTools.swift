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
                "id": .init(type: "string", description: "Preferred exact accessibility identifier"),
                "label": .init(type: "string", description: "Exact accessibility label fallback"),
                "contains_text": .init(type: "string", description: "Partial label fallback"),
                "value": .init(type: "string", description: "Value to type"),
                "session_id": .init(
                    type: "string",
                    description: "Optional session id; defaults to the server's default driver"
                )
            ],
            required: ["value"],
            outputSchema: ToolOutputSchema(
                properties: [
                    "verified": .init(type: "boolean", description: "Whether the field exposed the new value"),
                    "element_id": .init(type: "string", description: "Matched field accessibility identifier"),
                    "element_label": .init(type: "string", description: "Matched field label"),
                    "value_length": .init(type: "integer", description: "Length of the value typed")
                ],
                required: ["verified", "element_id", "element_label", "value_length"]
            )
        ),
        ToolDefinition(
            name: "assert_visible",
            title: "Assert Visible",
            description: "Poll until an element is visible or the timeout expires. Takes a precise"
                + " selector (id / label / contains_text) or, failing that, a natural-language"
                + " `description`. Prefer a selector: `description` is a text search over labels"
                + " and identifiers, so it can match the wrong element."
                + " Returns a pass/fail result with the matched element details.",
            properties: [
                "id": .init(type: "string", description: "Accessibility identifier. Preferred."),
                "label": .init(type: "string", description: "Exact accessibility label"),
                "contains_text": .init(type: "string", description: "Substring of the label"),
                "description": .init(
                    type: "string",
                    description: "Natural-language description, used only when no selector is given"
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
            // No `required`: one of id / label / contains_text / description must be present, which
            // a flat required list cannot express. The dispatch rejects the empty case by hand.
            required: [],
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
        ),
        assertionDefinition(
            name: "assert_enabled",
            title: "Assert Enabled",
            description: "Assert that a matching element is visible and enabled."
        ),
        assertionDefinition(
            name: "assert_absent",
            title: "Assert Absent",
            description: "Poll until no matching element is present."
        ),
        ToolDefinition(
            name: "assert_value",
            title: "Assert Value",
            description: "Assert a matching element's value without echoing the expected value.",
            properties: assertionSelectorProperties.merging([
                "expected": .init(type: "string", description: "Exact expected value"),
                "contains": .init(type: "string", description: "Expected substring")
            ]) { current, _ in current },
            required: []
        ),
        ToolDefinition(
            name: "assert_screen_changed",
            title: "Assert Screen Changed",
            description: "Assert that the screen differs from a token returned by get_screen_context.",
            properties: [
                "from_token": .init(type: "string", description: "Baseline screen_token"),
                "timeout_ms": .init(type: "string", description: "Maximum wait, default 3000ms"),
                "session_id": .init(type: "string", description: "Optional session id")
            ],
            required: ["from_token"]
        )
    ]

    private static let assertionSelectorProperties: [String: ToolInputProperty] = [
        "description": .init(type: "string", description: "Natural-language description"),
        "id": .init(type: "string", description: "Preferred exact accessibility identifier"),
        "label": .init(type: "string", description: "Exact accessibility label"),
        "contains_text": .init(type: "string", description: "Partial label match"),
        "timeout_ms": .init(type: "string", description: "Maximum wait, default 5000ms"),
        "session_id": .init(type: "string", description: "Optional session id")
    ]

    private static func assertionDefinition(name: String, title: String, description: String) -> ToolDefinition {
        ToolDefinition(
            name: name,
            title: title,
            description: description,
            properties: assertionSelectorProperties,
            required: []
        )
    }
}
