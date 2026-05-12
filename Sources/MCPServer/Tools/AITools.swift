public enum AITools {
    public static let names = definitions.map(\.name)

    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "ai_describe_screen",
            description: "Get a natural language description of the current screen using AI analysis"
        ),
        ToolDefinition(
            name: "ai_suggest_actions",
            description: "Get AI-suggested test actions based on the current screen state"
        ),
        ToolDefinition(
            name: "ai_suggest_actions_json",
            description: "Get AI-suggested test actions as structured JSON including confidence and accessibility feedback"
        ),
        ToolDefinition(
            name: "ai_find_by_description",
            description: "Find a UI element by natural language description (e.g. 'the login button', 'email field')",
            properties: [
                "description": .init(type: "string", description: "Natural language description of the element to find")
            ],
            required: ["description"]
        )
    ]
}
