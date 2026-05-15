import Foundation

/// One recorded tool invocation inside a session. Arguments are already
/// redacted by the recorder — never store raw secrets here.
public struct SessionAction: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let toolName: String
    public let arguments: [String: String]
    public let result: String
    public let isError: Bool

    public init(
        timestamp: Date,
        toolName: String,
        arguments: [String: String],
        result: String,
        isError: Bool
    ) {
        self.timestamp = timestamp
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.isError = isError
    }
}
