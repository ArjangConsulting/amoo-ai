import Foundation
import MCP
import TestSession

public struct ToolInputProperty: Sendable, Equatable {
    public var type: String
    public var description: String
    public var items: ToolItemsSchema?
    /// Known values, in canonical spelling. Exhaustive sets are published as a JSON Schema `enum`;
    /// open sets (a key name that may also be any single character) as `examples`. Studio uses both
    /// for completion, and only exhaustive sets for validation.
    public var values: [String]?
    public var valuesAreExhaustive: Bool

    public init(
        type: String,
        description: String,
        items: ToolItemsSchema? = nil,
        values: [String]? = nil,
        valuesAreExhaustive: Bool = true
    ) {
        self.type = type
        self.description = description
        self.items = items
        self.values = values
        self.valuesAreExhaustive = valuesAreExhaustive
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
    /// Groups the tool for catalogs such as Studio's console; set by `ToolCatalogMetadata`.
    public var category: ToolCategory?
    /// MCP `readOnlyHint`: the tool observes the device and app without changing them.
    public var readOnly: Bool?
    /// MCP `destructiveHint`: the tool may destroy app or device state irreversibly.
    public var destructive: Bool?

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
            annotations: .init(
                readOnlyHint: readOnly,
                // MCP defines destructiveHint only for tools that are not read-only.
                destructiveHint: readOnly == true ? nil : destructive
            ),
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
    if let values = property.values, !values.isEmpty {
        fields[property.valuesAreExhaustive ? "enum" : "examples"] = .array(values.map { .string($0) })
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
    /// What the session recorder persists instead of `content`, when `content` carries values that
    /// should reach the caller but not a report on disk (for example typed field text).
    public var recordedContent: String?

    public init(
        content: String,
        isError: Bool = false,
        structuredContent: Value? = nil,
        image: ToolImageContent? = nil,
        observedElements: [RecordedElement] = [],
        recordedContent: String? = nil
    ) {
        self.recordedContent = recordedContent
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
