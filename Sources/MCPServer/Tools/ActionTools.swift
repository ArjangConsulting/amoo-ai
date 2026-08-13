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
            description: "Swipe from one point to another",
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
            description: "Swipe in a direction from screen center or a specific element",
            properties: [
                "direction": .init(type: "string", description: "Swipe direction: up, down, left, or right"),
                "distance": .init(type: "string", description: "Swipe distance in points. Defaults to 300."),
                "duration_ms": .init(type: "string", description: "Swipe duration in milliseconds. Defaults to 400."),
                "element_id": .init(type: "string", description: "Accessibility ID of element to swipe on. Omit for screen-center swipe."),
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
            description: "Tap a UI element by accessibility ID, label, or partial text match",
            properties: [
                "id": .init(type: "string", description: "Accessibility identifier of the element"),
                "label": .init(type: "string", description: "Exact accessibility label of the element"),
                "contains_text": .init(type: "string", description: "Partial text to match in the element label")
            ]
        )
    ]
}
