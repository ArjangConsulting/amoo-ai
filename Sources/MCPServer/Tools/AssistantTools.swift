public enum AssistantTools {
    public static let names = definitions.map(\.name)

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "describe_screen",
            title: "Describe Screen",
            description: "Describe the current app screen using accessibility context and visible structure.",
            outputSchema: ToolOutputSchema(
                properties: [
                    "summary": .init(type: "string", description: "Human-readable screen summary"),
                    "screenTitle": .init(type: "string", description: "Detected screen title, when available"),
                    "interactableCount": .init(type: "integer", description: "Number of interactable elements")
                ],
                required: ["summary", "interactableCount"]
            )
        ),
        ToolDefinition(
            name: "suggest_test_actions",
            title: "Suggest Test Actions",
            description: "Suggest high-value test actions for the current screen with confidence and developer feedback.",
            outputSchema: ToolOutputSchema(
                properties: [
                    "screenIntent": .init(type: "string", description: "Inferred purpose of the current screen"),
                    "suggestedActions": .init(
                        type: "array",
                        description: "Ranked suggested test actions",
                        items: .object(
                            properties: [
                                "priority": .init(type: "integer", description: "1 = highest priority"),
                                "action": .init(type: "string", description: "Recommended action to perform"),
                                "reason": .init(type: "string", description: "Why this action is valuable")
                            ],
                            required: ["priority", "action", "reason"]
                        )
                    ),
                    "confidence": .init(type: "string", description: "Confidence level: high, medium, or low"),
                    "accessibilityIssues": .init(
                        type: "array",
                        description: "Issues limiting reliable AI testing",
                        items: .scalar(type: "string")
                    ),
                    "developerFeedback": .init(
                        type: "array",
                        description: "Concrete improvements for better AI support",
                        items: .scalar(type: "string")
                    )
                ],
                required: ["screenIntent", "suggestedActions", "confidence", "accessibilityIssues", "developerFeedback"]
            )
        ),
        ToolDefinition(
            name: "analyze_ai_testability",
            title: "Analyze AI Testability",
            description: "Analyze whether the current screen exposes enough accessibility context for reliable AI-driven testing.",
            outputSchema: ToolOutputSchema(
                properties: [
                    "screenSummary": .init(type: "string", description: "Current screen summary"),
                    "interactableCount": .init(type: "integer", description: "Number of app-relevant interactable elements"),
                    "confidence": .init(type: "string", description: "Confidence level: high, medium, or low"),
                    "diagnostics": .init(
                        type: "array",
                        description: "Detected testability issues",
                        items: .scalar(type: "string")
                    ),
                    "developerFeedback": .init(
                        type: "array",
                        description: "Recommended developer improvements",
                        items: .scalar(type: "string")
                    ),
                    "elementsWithIssues": .init(
                        type: "array",
                        description: "Elements that have accessibility issues, with id, label, type, frame coordinates, and issue description",
                        items: .object(
                            properties: [
                                "id": .init(type: "string", description: "Element identifier"),
                                "label": .init(type: "string", description: "Element label"),
                                "type": .init(type: "string", description: "Element type, when known"),
                                "issue": .init(type: "string", description: "Specific accessibility issue on this element"),
                                "frame": .init(type: "object", description: "Screen position: x, y (top-left origin), width, height in points")
                            ],
                            required: ["id", "label", "issue"]
                        )
                    )
                ],
                required: ["screenSummary", "interactableCount", "confidence", "diagnostics", "developerFeedback", "elementsWithIssues"]
            )
        ),
        ToolDefinition(
            name: "highlight_a11y_issues",
            title: "Highlight Accessibility Issues",
            description: "Take an annotated screenshot with colored stroke overlays on every element that has an accessibility issue."
                + " Red = missing label, orange = generic label, yellow = duplicate label."
                + " Returns the text report plus the annotated PNG as an image content block.",
            outputSchema: ToolOutputSchema(
                properties: [
                    "issueCount": .init(type: "integer", description: "Number of elements with accessibility issues"),
                    "issues": .init(
                        type: "array",
                        description: "List of elements with issues, matching the analyze_ai_testability format",
                        items: .object(
                            properties: [
                                "id": .init(type: "string", description: "Element identifier"),
                                "label": .init(type: "string", description: "Element label"),
                                "type": .init(type: "string", description: "Element type, when known"),
                                "issue": .init(type: "string", description: "Specific accessibility issue"),
                                "frame": .init(type: "object", description: "Position in points: x, y, width, height")
                            ],
                            required: ["id", "label", "issue"]
                        )
                    )
                ],
                required: ["issueCount", "issues"]
            )
        ),
        ToolDefinition(
            name: "find_element_by_description",
            title: "Find Element By Description",
            description: "Find UI elements by natural language description, using exposed labels and identifiers.",
            properties: [
                "description": .init(type: "string", description: "Natural language description of the element to find")
            ],
            required: ["description"],
            outputSchema: ToolOutputSchema(
                properties: [
                    "matches": .init(
                        type: "array",
                        description: "Matching elements with id, label, and type",
                        items: .object(
                            properties: [
                                "id": .init(type: "string", description: "Element identifier"),
                                "label": .init(type: "string", description: "Element label"),
                                "type": .init(type: "string", description: "Element type, when known")
                            ],
                            required: ["id", "label"]
                        )
                    ),
                    "query": .init(type: "string", description: "Original natural language description")
                ],
                required: ["matches", "query"]
            )
        )
    ]
}
