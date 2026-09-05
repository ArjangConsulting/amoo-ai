import Foundation
import MCP

/// Shared additions to the public tool contract; used by discovery and request validation.
enum ToolContracts {
    static func enrich(_ definition: ToolDefinition) -> ToolDefinition {
        var definition = definition
        if let schema = definition.outputSchema {
            var fields = schema.properties
            switch definition.name {
            case "describe_screen":
                fields["actions"] = .init(type: "array", description: "First seven actionable elements")
                fields["has_more"] = .init(type: "boolean", description: "Use find_elements for remaining elements")
                fields["screen_token"] = .init(type: "string", description: "Identity of the observed hierarchy")
            case "set_text", "fill_field":
                fields["verification_mode"] = .init(type: "string", description: "exact, masked_change, or unverified")
            case "end_session":
                fields["recording_health"] = .init(
                    type: "string",
                    description: "saved, failed, pending, unknown, or disabled"
                )
            case "get_session_report":
                fields["recording_health"] = .init(
                    type: "string",
                    description: "saved, failed, pending, unknown, or disabled"
                )
                fields["launchArguments"] = .init(type: "array", description: "Redacted launch arguments")
                fields["launchEnvironment"] = .init(type: "object", description: "Redacted launch environment")
                fields["testName"] = .init(type: "string", description: "Test name")
                fields["codegenIntent"] = .init(type: "object", description: "Persisted compiler context")
                fields["has_more"] = .init(type: "boolean", description: "More actions remain")
                fields["next_offset"] = .init(type: "integer", description: "Next action offset")
                fields["actions"] = .init(
                    type: "array",
                    description: "Recorded action page",
                    items: .scalar(type: "object")
                )
            default: break
            }
            var required = schema.required
            if definition.name == "assert_visible" {
                required.removeAll { $0 == "screen_summary" }
            }
            definition.outputSchema = ToolOutputSchema(properties: fields, required: required)
        }
        if ["list_sessions", "list_apps"].contains(definition.name), var schema = definition.outputSchema {
            schema.properties["total"] = .init(type: "integer", description: "Total results")
            schema.properties["has_more"] = .init(type: "boolean", description: "More results remain")
            schema.properties["next_offset"] = .init(type: "integer", description: "Next page offset")
            definition.outputSchema = schema
        }
        if definition.name == "get_view_hierarchy" {
            definition.properties["max_nodes"] = .init(
                type: "integer",
                description: "Maximum rendered nodes, 1–2000; default 200"
            )
        }
        if ["get_session_report", "list_sessions", "list_apps"].contains(definition.name) {
            definition.properties["limit"] = .init(type: "integer", description: "Page size, 1–2000; default 50")
            definition.properties["offset"] = .init(type: "integer", description: "Zero-based offset; default 0")
        }
        return definition
    }
}

/// Validates typed values once at the public execution boundary while retaining the CLI's
/// string representation. This rejects nonfinite coordinates and invalid numeric ranges.
struct ToolRequest: Sendable {
    let name: String
    let arguments: [String: String]

    init(name: String, arguments: [String: String]) throws {
        self.name = name
        self.arguments = arguments
        let nonnegative = ["timeout_ms", "duration_ms", "character_count", "offset"]
        let coordinates = ["x", "y", "from_x", "from_y", "to_x", "to_y", "latitude", "longitude", "distance", "scale"]
        for key in nonnegative + coordinates {
            guard let raw = arguments[key] else { continue }
            guard let number = Double(raw), number.isFinite,
                  !nonnegative.contains(key) || (number >= 0 && number <= 3_600_000 && number.rounded() == number),
                  key != "scale" || (number > 0 && number <= 1),
                  key != "latitude" || abs(number) <= 90,
                  key != "longitude" || abs(number) <= 180 else {
                throw ToolExecutionError(code: "invalid_argument", message: "Invalid numeric argument: \(key)")
            }
        }
        for key in ["return_image", "labeled_only", "include_offline", "all_frames"] {
            if let raw = arguments[key], boolArgument(raw) == nil {
                throw ToolExecutionError(code: "invalid_argument", message: "Invalid boolean argument: \(key)")
            }
        }
    }
}

/// Stable catalog profiles reduce client context without changing individual tool contracts.
public enum ToolProfile: String, Sendable, CaseIterable {
    case all, drive, record, audit

    func includes(_ name: String) -> Bool {
        let lifecycle = Set(SessionTools.names + CompanionTools.names)
        let driving = Set([
            "find_elements",
            "describe_screen",
            "get_screen_context",
            "current_app",
            "take_screenshot",
            "tap_element",
            "set_text",
            "type_text",
            "swipe_in_direction",
            "scroll",
            "press_back",
            "assert_visible",
            "assert_absent",
            "assert_value",
            "assert_enabled",
            "list_devices",
            "run_steps"
        ])
        switch self {
        case .all: return true
        case .drive:
            let management = ["start_session", "end_session", "companion_warm", "companion_status"]
            return driving.contains(name) || management.contains(name)
        case .record: return driving.contains(name) || lifecycle.contains(name)
        case .audit: return Set(AuditTools.names + AssistantTools.names).contains(name) || lifecycle.contains(name)
        }
    }
}
