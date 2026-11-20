import Foundation

/// A JSON value: a tool's structured result, a schema, or a decoded flow argument.
///
/// It replaced the MCP SDK's `Value` when amoo stopped running an MCP server, with the same cases
/// (less the unused `data`), accessors and JSON encoding, so reports and Studio payloads read the same.
public enum Value: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    /// The JSON form of an encodable value.
    public init(_ value: some Encodable) throws {
        if let value = value as? Self {
            self = value
        } else {
            self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
        }
    }

    public var isNull: Bool {
        self == .null
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case let .int(value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        guard case let .double(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var arrayValue: [Self]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var objectValue: [String: Self]? {
        guard case let .object(value) = self else { return nil }
        return value
    }
}

extension Value: Codable {
    /// Tries each JSON type in a fixed order, so a whole number decodes as `int`, not `double`.
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
        } else if let value = try? container.decode([Value].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Value].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
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
}

extension Value: CustomStringConvertible {
    public var description: String {
        switch self {
        case .null: ""
        case let .bool(value): value.description
        case let .int(value): value.description
        case let .double(value): value.description
        case let .string(value): value
        case let .array(value): value.description
        case let .object(value): value.description
        }
    }
}

extension Value: ExpressibleByNilLiteral {
    public init(nilLiteral _: ()) {
        self = .null
    }
}

extension Value: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension Value: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension Value: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension Value: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension Value: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Value...) {
        self = .array(elements)
    }
}

extension Value: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, Value)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
}
