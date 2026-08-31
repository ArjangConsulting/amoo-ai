import Foundation

/// One recorded tool invocation inside a session. Arguments are already
/// redacted by the recorder — never store raw secrets here.
public struct SessionAction: Sendable, Codable, Equatable {
    /// Why an action was recorded. Only test steps and assertions normally become generated code;
    /// recording also captures the exploration needed to discover a stable flow.
    public enum Intent: String, Sendable, Codable {
        case testStep
        case assertion
        case diagnostic
        case recovery
        case failedProbe
    }

    public let timestamp: Date
    public let toolName: String
    public let arguments: [String: String]
    public let result: String
    public let isError: Bool
    public let intent: Intent

    public init(
        timestamp: Date,
        toolName: String,
        arguments: [String: String],
        result: String,
        isError: Bool,
        intent: Intent = .testStep
    ) {
        self.timestamp = timestamp
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.intent = intent
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, toolName, arguments, result, isError, intent
    }

    /// Existing recordings predate intent classification. They preserve their former replayable
    /// behavior, while failed actions are still filtered by the compiler as a safety backstop.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        toolName = try container.decode(String.self, forKey: .toolName)
        arguments = try container.decode([String: String].self, forKey: .arguments)
        result = try container.decode(String.self, forKey: .result)
        isError = try container.decode(Bool.self, forKey: .isError)
        intent = try container.decodeIfPresent(Intent.self, forKey: .intent) ?? .testStep
    }
}
