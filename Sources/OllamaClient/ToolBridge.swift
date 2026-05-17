import Foundation

/// Bridges MCP `ToolDefinition` schemas to Ollama's tool-calling format.
/// This file has no dependency on MCPServer — it works with a simple
/// intermediate representation so the module stays lightweight.
public enum ToolBridge {
    /// Describes a tool in a format-agnostic way for conversion.
    public struct ToolSchema: Sendable {
        public var name: String
        public var description: String
        public var properties: [(key: String, type: String, description: String)]
        public var required: [String]

        public init(
            name: String,
            description: String,
            properties: [(key: String, type: String, description: String)],
            required: [String]
        ) {
            self.name = name
            self.description = description
            self.properties = properties
            self.required = required
        }
    }

    /// Converts a list of tool schemas to Ollama tool format.
    public static func toOllamaTools(_ schemas: [ToolSchema]) -> [OllamaTool] {
        schemas.map { schema in
            let props = schema.properties.reduce(into: [String: OllamaToolProperty]()) { result, prop in
                result[prop.key] = OllamaToolProperty(type: prop.type, description: prop.description)
            }
            return OllamaTool(
                name: schema.name,
                description: schema.description,
                parameters: OllamaToolParameters(
                    properties: props,
                    required: schema.required
                )
            )
        }
    }
}
