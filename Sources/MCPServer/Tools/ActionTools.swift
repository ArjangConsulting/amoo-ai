public enum ActionTools {
    public static let names = definitions.map(\.name)

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "tap",
            description: "Tap at a screen coordinate",
            properties: [
                "x": .init(type: "string", description: "X coordinate"),
                "y": .init(type: "string", description: "Y coordinate"),
                "unit": .init(
                    type: "string",
                    description: "Coordinate space: points (default), pixels, or normalized."
                        + " Screenshots are in pixels and gestures take points, so a position read"
                        + " off a screenshot needs unit=pixels — passing it as points lands"
                        + " off-screen and still reports success."
                )
            ],
            required: ["x", "y"]
        ),
        ToolDefinition(
            name: "double_tap",
            description: "Double tap at a screen coordinate",
            properties: [
                "x": .init(type: "string", description: "X coordinate"),
                "y": .init(type: "string", description: "Y coordinate"),
                "unit": .init(
                    type: "string",
                    description: "Coordinate space: points (default), pixels, or normalized."
                        + " Screenshots are in pixels and gestures take points, so a position read"
                        + " off a screenshot needs unit=pixels — passing it as points lands"
                        + " off-screen and still reports success."
                )
            ],
            required: ["x", "y"]
        ),
        ToolDefinition(
            name: "long_press",
            description: "Long press at a screen coordinate",
            properties: [
                "x": .init(type: "string", description: "X coordinate"),
                "y": .init(type: "string", description: "Y coordinate"),
                "duration_ms": .init(type: "string", description: "Hold duration in milliseconds. Defaults to 500.")
            ],
            required: ["x", "y"]
        ),
        ToolDefinition(
            name: "swipe",
            description: "Swipe between two screen coordinates. For a swipe on a list row, prefer"
                + " swipe_in_direction with the row's element_id; use this coordinate form only when"
                + " the row has no stable id or label, passing the point from find_elements so the"
                + " recorder can bind the gesture back to that element for codegen.",
            properties: [
                "from_x": .init(type: "string", description: "Start X coordinate"),
                "from_y": .init(type: "string", description: "Start Y coordinate"),
                "to_x": .init(type: "string", description: "End X coordinate"),
                "to_y": .init(type: "string", description: "End Y coordinate"),
                "duration_ms": .init(type: "string", description: "Swipe duration in milliseconds. Defaults to 300.")
            ],
            required: ["from_x", "from_y", "to_x", "to_y"]
        ),
        ToolDefinition(
            name: "swipe_in_direction",
            description: "Swipe in a direction from screen center or a specific element. This is the"
                + " canonical workflow for a swipe on one row of a list with per-row actions (e.g."
                + " SwiftUI List .swipeActions): call find_elements for the target row, then call"
                + " this tool with that row's element_id (preferred) or element_label. The companion"
                + " fails rather than guessing when the id/label does not uniquely identify one"
                + " element, and the recorded step keeps the row's identity, so generated code emits"
                + " an element-scoped gesture (e.g. groceriesTaskRow.swipeLeft()). Only when the"
                + " row has no stable id or label, fall back to the coordinate `swipe` tool with the"
                + " point-space coordinates from find_elements — the recorder then binds that gesture"
                + " to the resolved element. Never read coordinates off a screenshot.",
            properties: [
                "direction": .init(type: "string", description: "Swipe direction: up, down, left, or right"),
                "distance": .init(type: "string", description: "Swipe distance in points. Defaults to 300."),
                "duration_ms": .init(type: "string", description: "Swipe duration in milliseconds. Defaults to 400."),
                "element_id": .init(
                    type: "string",
                    description: "Accessibility ID of element to swipe on. Omit for screen-center swipe."
                ),
                "element_label": .init(type: "string", description: "Accessibility label of element to swipe on.")
            ],
            required: ["direction"]
        ),
        ToolDefinition(
            name: "scroll",
            description: "Scroll in a direction",
            properties: [
                "direction": .init(type: "string", description: "Scroll direction: up, down, left, or right"),
                "distance": .init(type: "string", description: "Scroll distance in points. Defaults to 300.")
            ],
            required: ["direction"]
        ),
        ToolDefinition(
            name: "type_text",
            description: "Type text using the keyboard",
            properties: [
                "text": .init(type: "string", description: "The text to type")
            ],
            required: ["text"]
        ),
        ToolDefinition(
            name: "clear_text",
            description: "Clear text from the focused text field",
            properties: [
                "character_count": .init(
                    type: "string",
                    description: "Number of characters to delete. Omit to clear all."
                )
            ]
        ),
        ToolDefinition(
            name: "set_text",
            title: "Set Text",
            description: "Atomically resolve, focus, clear, and fill a text field. Accessibility ID is preferred.",
            properties: [
                "id": .init(type: "string", description: "Exact accessibility identifier of the field"),
                "label": .init(type: "string", description: "Exact accessibility label of the field"),
                "contains_text": .init(type: "string", description: "Partial label fallback"),
                "value": .init(type: "string", description: "Value to set"),
                "scope": .init(
                    type: "string",
                    description: "Which process to resolve the field in: 'app' (default) or 'system'."
                ),
                "bundle_id": .init(
                    type: "string",
                    description: "Explicit bundle/package id to resolve the field in."
                )
            ],
            required: ["value"]
        ),
        ToolDefinition(
            name: "press_back",
            description: "Press the back button (Android) or perform the back gesture (iOS)"
        ),
        ToolDefinition(
            name: "press_home",
            description: "Press the home button to return to the home screen"
        ),
        ToolDefinition(
            name: "open_url",
            description: "Open a URL or deep link on the device",
            properties: [
                "url": .init(type: "string", description: "The URL or deep link to open")
            ],
            required: ["url"]
        ),
        ToolDefinition(
            name: "tap_element",
            description: "Tap a UI element by accessibility ID, label, or partial text match."
                + " For a control inside a list with per-row actions (e.g. SwiftUI List"
                + " .swipeActions), resolving by label can be unreliable if the label isn't unique"
                + " or the tree has shifted since the label was read — this can tap the wrong row."
                + " For row-specific or otherwise precise taps, call find_elements first and pass"
                + " the resolved element's id here; only when the row has no stable id or label,"
                + " use the coordinate `tap` tool with the point from find_elements.",
            properties: [
                "id": .init(type: "string", description: "Accessibility identifier of the element"),
                "label": .init(type: "string", description: "Exact accessibility label of the element"),
                "contains_text": .init(type: "string", description: "Partial text to match in the element label"),
                "scope": .init(
                    type: "string",
                    description: "Which process to resolve the element in: 'app' (default) or"
                        + " 'system' for system UI. Not usually needed — a lookup that finds"
                        + " nothing in the app retries against system UI automatically, so a"
                        + " button in a permission alert or the Sign in with Apple sheet is"
                        + " tappable by label without naming its process."
                ),
                "bundle_id": .init(
                    type: "string",
                    description: "Explicit bundle/package id to resolve the element in."
                )
            ]
        )
    ]
}
