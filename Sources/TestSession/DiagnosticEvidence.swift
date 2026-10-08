import Foundation

/// Versioned structured evidence from observations and explicitly authored journey assertions.
public struct DiagnosticEvidence: Codable, Sendable, Equatable {
    public static let toolNames: Set<String> = [
        "audit_app", "audit_security", "audit_accessibility", "audit_accessibility_native", "test_voiceover",
        "analyze_ai_testability", "highlight_a11y_issues", "suggest_test_actions"
    ]

    public static let structuredToolNames = toolNames.union(["assert_accessibility_journey"])

    public let schemaVersion: Int
    public let speechRetained: Bool
    public let payload: DiagnosticValue

    public init(payload: DiagnosticValue, speechRetained: Bool = false, schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion
        self.speechRetained = speechRetained
        self.payload = payload
    }

    public func redacted(using redactor: ArtifactRedactor) -> Self {
        Self(payload: payload.mapStrings(redactor.redact), speechRetained: speechRetained, schemaVersion: schemaVersion)
    }
}

/// Codable JSON without a dependency on an MCP client library in persisted session artifacts.
indirect public enum DiagnosticValue: Codable, Sendable, Equatable {
    case object([String: Self])
    case array([Self])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let decoded = try? value.decode(Bool.self) {
            self = .bool(decoded)
        } else if let decoded = try? value.decode(Double.self) {
            self = .number(decoded)
        } else if let decoded = try? value.decode(String.self) {
            self = .string(decoded)
        } else if let decoded = try? value.decode([String: Self].self) {
            self = .object(decoded)
        } else {
            self = try .array(value.decode([Self].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(fields): try value.encode(fields)
        case let .array(items): try value.encode(items)
        case let .string(text): try value.encode(text)
        case let .number(number): try value.encode(number)
        case let .bool(boolean): try value.encode(boolean)
        case .null: try value.encodeNil()
        }
    }

    public func mapStrings(_ transform: (String) -> String) -> Self {
        switch self {
        case let .object(fields): .object(fields.mapValues { $0.mapStrings(transform) })
        case let .array(items): .array(items.map { $0.mapStrings(transform) })
        case let .string(text): .string(transform(text))
        default: self
        }
    }
}
