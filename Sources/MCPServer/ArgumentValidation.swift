// swiftlint:disable multiline_arguments
import Foundation
import MCP

public extension MCPServer {
    /// Validates an invocation without connecting to or changing a device.
    static func validateArguments(tool: String, arguments: [String: String]) -> ToolResult? {
        do {
            _ = try ToolRequest(name: tool, arguments: arguments)
            return nil
        } catch let error as ToolExecutionError {
            return error.result
        } catch {
            return .error(String(describing: error))
        }
    }
}

extension ToolRequest {
    private static let contracts = Dictionary(uniqueKeysWithValues: MCPServer().toolDefinitions().map { ($0.name, $0) })

    static func validateSchema(name: String, arguments: [String: String]) throws {
        guard let definition = contracts[name] else {
            throw ToolExecutionError(code: "unknown_tool", message: "Unknown tool: \(name). Use get_capabilities.")
        }
        if let key = arguments.keys.sorted().first(where: { definition.properties[$0] == nil }) {
            let error = invalidArgument(key, example: "get_capabilities tool=\(name) lists accepted arguments")
            throw ToolExecutionError(
                code: error.code,
                message: "Unknown argument for \(name): \(key). Accepted: "
                    + definition.properties.keys.sorted().joined(separator: ", ") + ". " + error.message,
                extra: error.extra
            )
        }
        for key in definition.required where arguments[key] == nil {
            if ["text", "value"].contains(key), arguments["credential"] != nil {
                continue
            }
            let error = invalidArgument(key, example: "\(key)=\(exampleValue(definition.properties[key]))")
            throw ToolExecutionError(
                code: error.code,
                message: "Missing required argument: \(key). " + error
                    .message + acceptedValues(definition.properties[key]),
                extra: error.extra
            )
        }
        for (key, raw) in arguments {
            if let property = definition.properties[key] {
                try validateProperty(property, key: key, raw: raw)
            }
        }
        for (key, range) in ["limit": 1 ... 2000, "max_nodes": 1 ... 2000, "offset": 0 ... 1_000_000] {
            if let raw = arguments[key], Int(raw).map(range.contains) != true {
                throw invalidArgument(key, example: "\(key)=\(range.lowerBound)")
            }
        }
    }

    private static func validateProperty(_ property: ToolInputProperty, key: String, raw: String) throws {
        if raw.contains("\0") {
            throw invalidArgument(key, example: "Omit NUL characters")
        }
        let valid = switch property.type {
        case "boolean": boolArgument(raw) != nil
        case "integer": Int(raw) != nil
        case "number": Double(raw).map(\.isFinite) == true
        case "array": (try? JSONDecoder().decode([Value].self, from: Data(raw.utf8))) != nil
        case "object": (try? JSONDecoder().decode([String: Value].self, from: Data(raw.utf8))) != nil
        default: true
        }
        if !valid {
            throw invalidArgument(key, example: "\(key)=\(exampleValue(property))")
        }
        let candidate = key == "platform" ? raw.lowercased() : raw
        if property.valuesAreExhaustive, let values = property.values, !values.contains(candidate) {
            if key == "platform" {
                let error = invalidArgument(key, example: "platform=ios")
                throw ToolExecutionError(
                    code: error.code, message: "Unknown platform. " + error.message, extra: error.extra
                )
            }
            let error = invalidArgument(key, example: "\(key)=\(values.first ?? "")")
            throw ToolExecutionError(
                code: error.code,
                message: error.message + acceptedValues(property),
                extra: error.extra
            )
        }
    }

    static func invalidArgument(_ key: String, example: String) -> ToolExecutionError {
        ToolExecutionError(
            code: "invalid_argument", message: "Invalid or missing argument '\(key)'. Example: \(example).",
            extra: ["argument": .string(key), "example": .string(example), "dispatch_status": .string("not_dispatched")]
        )
    }

    private static func acceptedValues(_ property: ToolInputProperty?) -> String {
        property?.values.map { " Accepted: " + $0.joined(separator: ", ") + "." } ?? ""
    }

    private static func exampleValue(_ property: ToolInputProperty?) -> String {
        switch property?.type {
        case "boolean": "true"
        case "number", "integer": "1"
        case "array": "[]"
        case "object": "{}"
        default: "\"Example value\""
        }
    }
}

// swiftlint:enable multiline_arguments
