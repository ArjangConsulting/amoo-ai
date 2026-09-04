import Foundation

/// The sliver of the Chrome DevTools Protocol the webview tools need: a request/response
/// envelope over a single WebSocket, plus the `/json` target list.
///
/// Android's `WebView.setWebContentsDebuggingEnabled(true)` exposes exactly this on
/// `localabstract:webview_devtools_remote_<pid>`; the same envelope is reused for the iOS
/// `ios-webkit-debug-proxy` bridge (see `docs/webview-introspection.md`).
enum CDP {
    /// One outbound `{id, method, params}` message.
    struct Request: Encodable {
        let id: Int
        let method: String
        let params: [String: JSONValue]
    }

    /// One inbound message — either a command reply (`id` set) or an event (`method` set).
    struct Message: Decodable {
        let id: Int?
        let method: String?
        let result: JSONValue?
        let error: CommandError?
    }

    struct CommandError: Decodable, Equatable {
        let code: Int
        let message: String
    }

    /// One entry from `GET http://<host>:<port>/json`.
    struct Target: Decodable, Equatable {
        let id: String
        let type: String?
        let title: String?
        let url: String?
        let webSocketDebuggerUrl: String?

        var isInspectablePage: Bool {
            (type ?? "page") == "page" && webSocketDebuggerUrl != nil
        }
    }

    static func encode(_ request: Request) throws -> Data {
        try JSONEncoder().encode(request)
    }

    static func decode(_ data: Data) throws -> Message {
        try JSONDecoder().decode(Message.self, from: data)
    }

    static func decodeTargets(_ data: Data) throws -> [Target] {
        try JSONDecoder().decode([Target].self, from: data)
    }
}

/// A minimal JSON value so CDP params/results round-trip without a concrete type per method.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrepresentable JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Serialize back to a compact JSON string (what `webview_eval` returns to the caller).
    var jsonString: String {
        switch self {
        case .null: return "null"
        case let .bool(value): return value ? "true" : "false"
        case let .number(value):
            return value.rounded() == value && abs(value) < 1e15
                ? String(Int64(value))
                : String(value)
        case let .string(value):
            let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
            return String(bytes: data, encoding: .utf8) ?? "\"\""
        case .array, .object:
            let data = (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
            return String(bytes: data, encoding: .utf8) ?? "null"
        }
    }

    subscript(key: String) -> Self? {
        if case let .object(dict) = self {
            return dict[key]
        }
        return nil
    }
}
