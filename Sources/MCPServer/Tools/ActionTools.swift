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
                "duration_ms": .init(type: "string", description: "Swipe duration in milliseconds. Defaults to 300."),
                "unit": .init(
                    type: "string",
                    description: "Coordinate space for all four coordinates: points (default), pixels,"
                        + " or normalized."
                )
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
                + " to the resolved element. Never read coordinates off a screenshot. To aim at a"
                + " point without computing an end point, pass from_x/from_y: the swipe starts there"
                + " and travels distance in direction.",
            properties: [
                "direction": .init(type: "string", description: "Swipe direction: up, down, left, or right"),
                "distance": .init(type: "string", description: "Swipe distance in points. Defaults to 300."),
                "duration_ms": .init(
                    type: "string",
                    description: "Swipe duration in milliseconds. Defaults to 400, which a scroll view treats as a"
                        + " fling and carries to the end of a long list; use 1500 or more for a controlled drag."
                ),
                "element_id": .init(
                    type: "string",
                    description: "Accessibility ID of element to swipe on. Omit for screen-center swipe."
                ),
                "element_label": .init(type: "string", description: "Accessibility label of element to swipe on."),
                "from_x": .init(
                    type: "string",
                    description: "Optional start X, e.g. a cell's hitPoint from find_elements. Requires"
                        + " from_y; cannot be combined with element_id or element_label."
                ),
                "from_y": .init(type: "string", description: "Optional start Y. Requires from_x."),
                "unit": .init(
                    type: "string",
                    description: "Coordinate space for from_x/from_y: points (default), pixels, or"
                        + " normalized. distance is always in points."
                )
            ],
            required: ["direction"]
        ),
        ToolDefinition(
            name: "scroll",
            description: "Scroll the view so content in a direction comes into view: down reveals what is"
                + " below (the finger travels up), up reveals what is above. This is the opposite of"
                + " swipe_in_direction, whose direction is the finger's. To bring one element on screen,"
                + " use scroll_to_element.",
            properties: [
                "direction": .init(type: "string", description: "Which way to scroll: up, down, left, or right"),
                "distance": .init(
                    type: "string",
                    description: "Finger travel in points, centred on the screen; at least 10. Defaults to 300."
                )
            ],
            required: ["direction"]
        ),
        ToolDefinition(
            name: "scroll_to_element",
            description: "Scroll until an element is on screen and tappable, then stop. Matches by id, label,"
                + " or contains_text; scrolls down by default, and reverses once it reaches the end of the"
                + " content. Fails with the number of attempts when the element never appears.",
            properties: [
                "id": .init(type: "string", description: "Accessibility identifier of the element"),
                "label": .init(type: "string", description: "Exact accessibility label of the element"),
                "contains_text": .init(type: "string", description: "Partial text to match in the element label"),
                "direction": .init(type: "string", description: "First scroll direction. Defaults to down."),
                "max_attempts": .init(type: "string", description: "Scroll gestures to try. Defaults to 8."),
                "distance": .init(type: "string", description: "Finger travel per scroll in points. Defaults to 300.")
            ]
        ),
        ToolDefinition(
            name: "dismiss_keyboard",
            description: "Hide the on-screen keyboard using an unambiguous button labeled Hide keyboard or"
                + " Dismiss keyboard. Fails without acting when no dedicated dismissal control is available."
                + " Never sends Return/Escape, taps Done, or swipes: those can submit forms or close sheets."
                + " Use tap_element with an explicit app control when that action is intended.",
            properties: [:]
        ),
        ToolDefinition(
            name: "type_text",
            description: "Type text using the keyboard",
            properties: [
                "text": .init(type: "string", description: "The text to type. Omit when passing credential.")
            ]
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
                "value": .init(type: "string", description: "Value to set. Omit when passing credential."),
                "scope": .init(
                    type: "string",
                    description: "Which process to resolve the field in: 'app' (default) or 'system'."
                ),
                "bundle_id": .init(
                    type: "string",
                    description: "Explicit bundle/package id to resolve the field in."
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
                ),
                "check_hittable": .init(
                    type: "string",
                    description: "Before tapping, read the hierarchy and refuse a target another control"
                        + " (keyboard, sheet) covers, a clipping container cuts off, or that is off-screen."
                        + " Runs by default, giving up after hittable_timeout_ms; 'true' makes it required,"
                        + " 'false' skips it. Android accessibility inspection cannot establish occlusion: the default"
                        + " proceeds unchecked, while 'true' returns an unsupported-check error."
                ),
                "hittable_timeout_ms": .init(
                    type: "string",
                    description: "Budget for the default check, in milliseconds (default 1500). A hierarchy"
                        + " read that takes longer is abandoned and the tap proceeds unchecked; 0 disables."
                ),
                "check_effect": .init(
                    type: "string",
                    description: "Compare semantic snapshots before and after the tap. An unchanged tree reports"
                        + " semantic_change=false and observable_change=false; visual effect is unverified. Runs within"
                        + " effect_timeout_ms; 'true' makes it required, 'false' skips it."
                ),
                "effect_timeout_ms": .init(
                    type: "string",
                    description: "Budget for the default effect check, in milliseconds (default 1500). A hierarchy"
                        + " read that takes longer is abandoned and the result carries no effect report; 0"
                        + " disables."
                )
            ]
        )
    ]
}
