public enum AssistantTools {
    public static let names = definitions.map(\.name)

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "describe_screen",
            title: "Describe Screen",
            description: "Describe the current app screen using accessibility context and visible structure."
        ),
        ToolDefinition(
            name: "suggest_test_actions",
            title: "Suggest Test Actions",
            description: "Suggest high-value test actions for the current screen with confidence and developer feedback.",
            outputSchema: ToolOutputSchema(
                properties: [
                    "screenIntent": .init(type: "string", description: "Inferred purpose of the current screen"),
                    "suggestedActions": .init(type: "array", description: "Ranked suggested test actions"),
                    "confidence": .init(type: "string", description: "Confidence level: high, medium, or low"),
                    "accessibilityIssues": .init(type: "array", description: "Issues limiting reliable AI testing"),
                    "developerFeedback": .init(type: "array", description: "Concrete improvements for better AI support")
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
                    "diagnostics": .init(type: "array", description: "Detected testability issues"),
                    "developerFeedback": .init(type: "array", description: "Recommended developer improvements")
                ],
                required: ["screenSummary", "interactableCount", "confidence", "diagnostics", "developerFeedback"]
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
                    "matches": .init(type: "array", description: "Matching elements with id, label, and type"),
                    "query": .init(type: "string", description: "Original natural language description")
                ],
                required: ["matches", "query"]
            )
        )
    ]
}
