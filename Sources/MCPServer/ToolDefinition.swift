import Foundation

public struct ToolInputProperty: Sendable, Equatable {
    public var type: String
    public var description: String

    public init(type: String, description: String) {
        self.type = type
        self.description = description
    }
}

public struct ToolDefinition: Sendable {
    public var name: String
    public var description: String
    public var properties: [String: ToolInputProperty]
    public var required: [String]

    public init(
        name: String,
        description: String,
        properties: [String: ToolInputProperty] = [:],
        required: [String] = []
    ) {
        self.name = name
        self.description = description
        self.properties = properties
        self.required = required
    }
}

public struct ToolResult: Sendable, Equatable {
    public var content: String
    public var isError: Bool

    public init(content: String, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func success(_ content: String) -> Self {
        Self(content: content)
    }

    public static func error(_ content: String) -> Self {
        Self(content: content, isError: true)
    }
}
