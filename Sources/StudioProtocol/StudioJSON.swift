import Foundation

/// A JSON value that is `Sendable`, for tool schemas and model-supplied tool arguments.
indirect public enum StudioJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: Self].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Parses JSON text; nil when it is not valid JSON.
    public static func parse(_ text: String) -> Self? {
        try? JSONDecoder().decode(Self.self, from: Data(text.utf8))
    }

    /// Compact JSON text with sorted keys, so equal values always print the same way.
    public var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "null"
    }

    /// The value as a tool-argument string: strings as-is, whole numbers without a fraction, and
    /// arrays and objects as JSON text, matching how MCP clients pass arguments to amoo.
    public var argumentText: String {
        switch self {
        case .null: ""
        case let .bool(value): String(value)
        case let .int(value): String(value)
        case let .double(value): Self.numberText(value)
        case let .string(value): value
        case .array, .object: jsonText
        }
    }

    /// Whole numbers print without a fraction (`3`, not `3.0`), as a person would type them.
    private static func numberText(_ value: Double) -> String {
        guard value.rounded() == value, abs(value) < 1e15 else { return String(value) }
        return String(Int(value))
    }

    public subscript(key: String) -> Self? {
        if case let .object(fields) = self {
            fields[key]
        } else {
            nil
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }

    public var intValue: Int? {
        switch self {
        case let .int(value): value
        case let .double(value): Int(exactly: value)
        default: nil
        }
    }

    public var arrayValue: [Self]? {
        if case let .array(values) = self {
            values
        } else {
            nil
        }
    }
}
