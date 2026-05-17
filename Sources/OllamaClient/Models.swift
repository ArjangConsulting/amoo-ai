import Foundation

// MARK: - Request Types

public struct ChatMessage: Sendable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public var role: Role
    public var content: String
    /// For tool result messages, the name of the tool that produced this result.
    public var toolCallID: String?

    public init(role: Role, content: String, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
    }

    var asJSON: [String: Any] {
        var dict: [String: Any] = [
            "role": role.rawValue,
            "content": content
        ]
        if let toolCallID {
            dict["tool_call_id"] = toolCallID
        }
        return dict
    }
}

public struct OllamaTool: Sendable {
    public var name: String
    public var description: String
    public var parameters: OllamaToolParameters

    public init(name: String, description: String, parameters: OllamaToolParameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    var asJSON: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters.asJSON
            ] as [String: Any]
        ]
    }
}

public struct OllamaToolParameters: Sendable {
    public var type: String
    public var properties: [String: OllamaToolProperty]
    public var required: [String]

    public init(type: String = "object", properties: [String: OllamaToolProperty], required: [String]) {
        self.type = type
        self.properties = properties
        self.required = required
    }

    var asJSON: [String: Any] {
        [
            "type": type,
            "properties": properties.mapValues(\.asJSON),
            "required": required
        ]
    }
}

public struct OllamaToolProperty: Sendable {
    public var type: String
    public var description: String

    public init(type: String, description: String) {
        self.type = type
        self.description = description
    }

    var asJSON: [String: Any] {
        ["type": type, "description": description]
    }
}

// MARK: - Response Types

public struct ChatResponse: Sendable {
    public var role: String
    public var content: String
    public var toolCalls: [ToolCall]
    public var doneReason: String?

    public var hasToolCalls: Bool { !toolCalls.isEmpty }
}

public struct ToolCall: Sendable {
    public var name: String
    public var arguments: [String: String]
}

// MARK: - Errors

public enum OllamaError: Error, CustomStringConvertible {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case parseError(String)
    case modelNotAvailable(String)
    case connectionFailed

    public var description: String {
        switch self {
        case .invalidResponse:
            "Invalid response from Ollama"
        case let .httpError(code, body):
            "Ollama HTTP \(code): \(body)"
        case let .parseError(msg):
            "Failed to parse Ollama response: \(msg)"
        case let .modelNotAvailable(model):
            "Model '\(model)' is not available. Run: ollama pull \(model)"
        case .connectionFailed:
            "Cannot connect to Ollama. Is it running? (ollama serve)"
        }
    }
}
