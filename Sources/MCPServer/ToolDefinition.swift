import Foundation
import MCP
import TestSession

public struct ToolInputProperty: Sendable, Equatable {
    public var type: String
    public var description: String
    public var items: ToolItemsSchema?

    public init(type: String, description: String, items: ToolItemsSchema? = nil) {
        self.type = type
        self.description = description
        self.items = items
    }
}

indirect public enum ToolItemsSchema: Sendable, Equatable {
    case scalar(type: String)
    case object(properties: [String: ToolInputProperty], required: [String])
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
            "properties": .object(properties.mapValues(toolPropertyValue)),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false)
        ])
    }

    private func outputSchemaValue() -> Value? {
        guard let outputSchema else { return nil }
        return .object([
            "type": .string("object"),
            "properties": .object(outputSchema.properties.mapValues(toolPropertyValue)),
            "required": .array(outputSchema.required.map { .string($0) }),
            "additionalProperties": .bool(false)
        ])
    }
}

private func toolPropertyValue(_ property: ToolInputProperty) -> Value {
    var fields: [String: Value] = [
        "type": .string(property.type),
        "description": .string(property.description)
    ]
    if let items = property.items {
        fields["items"] = itemsSchemaValue(items)
    }
    return .object(fields)
}

private func itemsSchemaValue(_ schema: ToolItemsSchema) -> Value {
    switch schema {
    case let .scalar(type):
        .object(["type": .string(type)])
    case let .object(properties, required):
        .object([
            "type": .string("object"),
            "properties": .object(properties.mapValues(toolPropertyValue)),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false)
        ])
    }
}

/// An image payload returned alongside a tool result as an MCP image content block.
public struct ToolImageContent: Sendable, Equatable {
    public var data: Data
    public var mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public struct ToolResult: Sendable, Equatable {
    public var content: String
    public var isError: Bool
    public var structuredContent: Value?
    /// Optional image (screenshot, annotated overlay, …) returned as an MCP image content block.
    public var image: ToolImageContent?
    public var observedElements: [RecordedElement]

    public init(
        content: String,
        isError: Bool = false,
        structuredContent: Value? = nil,
        image: ToolImageContent? = nil,
        observedElements: [RecordedElement] = []
    ) {
        self.content = content
        self.isError = isError
        self.structuredContent = structuredContent
        self.image = image
        self.observedElements = observedElements
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
        var items: [Tool.Content] = [.text(text: content, annotations: nil, _meta: nil)]
        if let image {
            items.append(.image(
                data: image.data.base64EncodedString(),
                mimeType: image.mimeType,
                annotations: nil,
                _meta: nil
            ))
        }
        return CallTool.Result(
            content: items,
            structuredContent: structuredContent,
            isError: isError
        )
    }
}
