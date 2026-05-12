import Foundation
import MCP

public struct ToolInputProperty: Sendable, Equatable {
    public var type: String
    public var description: String

    public init(type: String, description: String) {
        self.type = type
        self.description = description
    }
}

public struct ToolOutputSchema: Sendable, Equatable {
    public var properties: [String: ToolInputProperty]
    public var required: [String]

    public init(properties: [String: ToolInputProperty], required: [String]) {
        self.properties = properties
        self.required = required
    }
}

public struct ToolDefinition: Sendable {
    public var name: String
    public var title: String?
    public var description: String
    public var properties: [String: ToolInputProperty]
    public var required: [String]
    public var outputSchema: ToolOutputSchema?

    public init(
        name: String,
        title: String? = nil,
        description: String,
        properties: [String: ToolInputProperty] = [:],
        required: [String] = [],
        outputSchema: ToolOutputSchema? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.properties = properties
        self.required = required
        self.outputSchema = outputSchema
    }

    public func mcpTool() -> MCP.Tool {
        MCP.Tool(
            name: name,
            title: title,
            description: description,
            inputSchema: inputSchemaValue(),
            outputSchema: outputSchemaValue()
        )
    }

    private func inputSchemaValue() -> Value {
        guard !properties.isEmpty else {
            return .object([
                "type": .string("object"),
                "additionalProperties": .bool(false)
            ])
        }

        return .object([
            "type": .string("object"),
            "properties": .object(properties.mapValues { property in
                .object([
                    "type": .string(property.type),
                    "description": .string(property.description)
                ])
            }),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false)
        ])
    }

    private func outputSchemaValue() -> Value? {
        guard let outputSchema else { return nil }
        return .object([
            "type": .string("object"),
            "properties": .object(outputSchema.properties.mapValues { property in
                .object([
                    "type": .string(property.type),
                    "description": .string(property.description)
                ])
            }),
            "required": .array(outputSchema.required.map { .string($0) }),
            "additionalProperties": .bool(false)
        ])
    }
}

public struct ToolResult: Sendable, Equatable {
    public var content: String
    public var isError: Bool
    public var structuredContent: Value?

    public init(content: String, isError: Bool = false, structuredContent: Value? = nil) {
        self.content = content
        self.isError = isError
        self.structuredContent = structuredContent
    }

    public static func success(_ content: String) -> Self {
        Self(content: content)
    }

    public static func success(_ content: String, structuredContent: Value) -> Self {
        Self(content: content, structuredContent: structuredContent)
    }

    public static func error(_ content: String) -> Self {
        Self(content: content, isError: true)
    }

    public func mcpResult() -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: content, annotations: nil, _meta: nil)],
            structuredContent: structuredContent,
            isError: isError
        )
    }
}
