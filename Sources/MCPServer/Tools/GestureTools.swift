/// Gestures whose ends can each be an element or a point: drag-and-drop and two-finger pinch.
public enum GestureTools {
    public static let names = definitions.map(\.name)

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "drag",
            description: "Drag and drop: press the source, hold until it lifts, move onto the target, and"
                + " release. Name each end by element (preferred: id/label/contains_text for the source,"
                + " to_id/to_label/to_contains_text for the target) so the recording becomes a generated"
                + " test step; a coordinate end (from_x/from_y, to_x/to_y) works live but is excluded from"
                + " generated tests. Refuses a source another control covers or that is off-screen."
                + " Verify the drop with an assertion afterwards.",
            properties: [
                "id": .init(type: "string", description: "Accessibility identifier of the element to drag"),
                "label": .init(type: "string", description: "Exact accessibility label of the element to drag"),
                "contains_text": .init(type: "string", description: "Partial text of the element to drag"),
                "parent_id": .init(type: "string", description: "Only match the source inside this ancestor"),
                "index": .init(type: "string", description: "0-based pick among several source matches"),
                "first": .init(type: "string", description: "true to take the first of several source matches"),
                "to_id": .init(type: "string", description: "Accessibility identifier of the drop target"),
                "to_label": .init(type: "string", description: "Exact accessibility label of the drop target"),
                "to_contains_text": .init(type: "string", description: "Partial text of the drop target"),
                "to_parent_id": .init(type: "string", description: "Only match the target inside this ancestor"),
                "to_index": .init(type: "string", description: "0-based pick among several target matches"),
                "to_first": .init(type: "string", description: "true to take the first of several target matches"),
                "from_x": .init(type: "string", description: "Source X, instead of a source element"),
                "from_y": .init(type: "string", description: "Source Y. Requires from_x."),
                "to_x": .init(type: "string", description: "Target X, instead of a target element"),
                "to_y": .init(type: "string", description: "Target Y. Requires to_x."),
                "unit": .init(
                    type: "string",
                    description: "Coordinate space for the x/y arguments: points (default), pixels, or normalized."
                ),
                "hold_ms": .init(
                    type: "string",
                    description: "Hold at the source before moving, in milliseconds. Defaults to 800, long"
                        + " enough for iOS and Android drag-and-drop to lift the item; 0 starts moving at once."
                ),
                "duration_ms": .init(
                    type: "string",
                    description: "Travel time from source to target in milliseconds. Defaults to 1000."
                ),
                "check_hittable": .init(
                    type: "string",
                    description: "Refuse a source element that is covered or off-screen. Runs by default;"
                        + " 'true' makes it required, 'false' skips it."
                )
            ]
        ),
        ToolDefinition(
            name: "pinch",
            description: "Two-finger pinch: scale above 1 spreads the fingers (zoom in), below 1 brings them"
                + " together (zoom out). Pinches an element named by id/label/contains_text (preferred, and"
                + " what a generated test can replay), a point (x/y), or the screen centre when neither is"
                + " given. Fingers stay inside the screen, so an extreme scale is clamped; the result reports"
                + " the scale performed. Not available on macOS.",
            properties: [
                "scale": .init(
                    type: "string",
                    description: "Finger separation at the end over the start, e.g. 2 or 0.5"
                ),
                "velocity": .init(
                    type: "string",
                    description: "Scale change per second. Defaults to a 0.6s gesture."
                ),
                "id": .init(type: "string", description: "Accessibility identifier of the element to pinch"),
                "label": .init(type: "string", description: "Exact accessibility label of the element to pinch"),
                "contains_text": .init(type: "string", description: "Partial text of the element to pinch"),
                "parent_id": .init(type: "string", description: "Only match the element inside this ancestor"),
                "index": .init(type: "string", description: "0-based pick among several matches"),
                "first": .init(type: "string", description: "true to take the first of several matches"),
                "x": .init(type: "string", description: "Centre X, instead of an element"),
                "y": .init(type: "string", description: "Centre Y. Requires x."),
                "unit": .init(
                    type: "string",
                    description: "Coordinate space for x/y: points (default), pixels, or normalized."
                )
            ],
            required: ["scale"]
        )
    ]
}
