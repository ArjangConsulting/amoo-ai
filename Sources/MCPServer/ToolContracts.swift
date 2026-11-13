// swiftlint:disable multiline_arguments
import Foundation
import MCP

/// Shared additions to the public tool contract; used by discovery and request validation.
enum ToolContracts {
    // Catalog enrichment is a linear mapping of tool-specific schema fields.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func enrich(_ definition: ToolDefinition) -> ToolDefinition {
        var definition = definition
        // These three arguments sit on nearly every tool, so their wording is paid for some eighty
        // times in `tools/list`. The full contract is stated once, where a caller first meets it.
        definition.properties["run_id"] = .init(
            type: "string",
            description: definition.name == "start_session"
                ? "Caller UUID (e.g. 550e8400-e29b-41d4-a716-446655440000) for telemetry across startup,"
                + " recovery and abandoned sessions; any other format is rejected as invalid_argument"
                : "Run UUID from start_session; a non-UUID is rejected"
        )
        if definition.name.hasPrefix("webview_") {
            definition.properties["platform"] = .init(type: "string", description: "Override inspector platform")
        }
        if definition.properties["session_id"] != nil {
            definition.properties["response_mode"] = .init(
                type: "string",
                description: ["find_elements", "tap_element", "describe_screen"].contains(definition.name)
                    ? "Default compacts element rows; compact also shortens the text and omits"
                    + " default-valued tap_element fields; full keeps semantics and bounds."
                    + " Assertions retain identical proof fields"
                    : "compact shortens the result; full keeps semantics and bounds",
                values: ["full", "compact"]
            )
        }
        if definition.name.hasPrefix("assert_") {
            definition.properties["precondition"] = .init(
                type: "boolean", description: "Setup assertion: a mismatch blocks coverage as a precondition failure"
            )
            definition.properties["check_id"] = .init(
                type: "string", description: "Requested verification check ID declared at start_session"
            )
        }
        if definition.name == "start_session" {
            definition.properties["checks"] = .init(
                type: "array", description: "All required verification check IDs; untested until explicitly asserted",
                items: .scalar(type: "string")
            )
        }
        if ["tap_element", "find_elements"].contains(definition.name) {
            definition.properties["timeout_ms"] = .init(
                type: "integer", description: "Selector observation budget in milliseconds; default 5000"
            )
        }
        if let schema = definition.outputSchema {
            var fields = schema.properties
            if definition.name.hasPrefix("assert_") || !ToolCatalogMetadata.isReadOnly(definition.name) {
                fields["outcome_status"] = .init(
                    type: "string",
                    description: "dispatched, target_state_confirmed, target_state_mismatch or inconclusive"
                )
                fields["dispatch_status"] = .init(type: "string", description: "completed, unknown or not_dispatched")
                fields["repeated_call"] = .init(
                    type: "boolean", description: "Same tool and arguments as the previous mutating call"
                )
                fields["repeat_count"] = .init(type: "integer", description: "Consecutive identical calls")
                fields["repeat_hint"] = .init(type: "string", description: "How to avoid the repeat")
                fields["postcondition_verified"] = .init(
                    type: "boolean",
                    description: "Whether an app outcome was verified"
                )
            }
            if ["find_elements", "get_screen_context", "tap_element"].contains(definition.name) {
                fields["observation_status"] = .init(type: "string", description: "selector_miss or empty_observation")
                fields["navigation_status"] = .init(
                    type: "string",
                    description: "Navigation is unassessed after a miss"
                )
                fields["recovery"] = .init(type: "array", description: "Bounded recovery suggestions")
                fields["foreground_app_id"] = .init(type: "string", description: "Observed foreground app")
                fields["target_app_id"] = .init(type: "string", description: "Bound inspection target")
                fields["selector_hint"] = .init(type: "string", description: "Accessible text granularity guidance")
                fields["available_controls"] = .init(
                    type: "array",
                    description: "Up to eight nearby accessible candidates, with roles"
                )
            }
            switch definition.name {
            case "device_launch_app":
                fields["launch"] = .init(
                    type: "object",
                    description: "Fresh process and configuration delivery receipt"
                )
                fields["target_app_id"] = .init(type: "string", description: "Requested inspection target")
            case "get_screen_context":
                fields["element_count"] = .init(type: "integer", description: "Observed nodes including the root")
                fields["semantic_readiness"] = .init(
                    type: "string",
                    description: "empty or queryable; not render readiness"
                )
            case "take_screenshot":
                fields["capture_suspect"] = .init(
                    type: "boolean",
                    description: "Advisory blank or invalid capture warning"
                )
                fields["capture_analysis"] = .init(
                    type: "string",
                    description: "Pixel assessment or analysis_unavailable"
                )
                fields["viewport"] = .init(
                    type: "object",
                    description: "Observed native viewport and gesture dimensions"
                )
                fields["foreground_app_id"] = .init(type: "string", description: "Observed foreground app or unknown")
                fields["target_app_id"] = .init(type: "string", description: "Bound target app or unknown")
                fields["scaling_status"] = .init(type: "string", description: "applied, unavailable or not_requested")
            case "start_session":
                fields["run_id"] = .init(type: "string", description: "Run telemetry UUID, retained on startup failure")
                fields["artifact_snapshot"] = .init(
                    type: "object",
                    description: "Validated session-owned artifact and hash"
                )
                fields["startup"] = .init(
                    type: "object",
                    description: "Installation, fresh-process launch and readiness"
                )
            case "tap_element":
                fields["expected_effect_met"] = .init(
                    type: "boolean",
                    description: "With expect_*: whether the expected element appeared (or went) in time;"
                        + " omitted when inconclusive (see expectation_status)"
                )
                fields["expectation_status"] = .init(
                    type: "string",
                    description: "met, not_met, already_satisfied (expect_absent on an element that was gone"
                        + " before the tap) or unverified"
                )
                fields["target_state"] = .init(
                    type: "object", description: "Observed selected/checked/value state; null when unavailable"
                )
                fields["tap_point"] = .init(type: "object", description: "Where the tap landed, {x, y} in points")
                fields["hittability_checked"] = .init(
                    type: "boolean",
                    description: "Whether the tap point was checked against the hierarchy"
                )
            case "describe_screen":
                fields["actions"] = .init(type: "array", description: "First seven actionable elements")
                fields["has_more"] = .init(type: "boolean", description: "Use find_elements for remaining elements")
                fields["screen_token"] = .init(type: "string", description: "Identity of the observed hierarchy")
            case "set_text", "fill_field":
                fields["verification_mode"] = .init(type: "string", description: "exact, masked_change, or unverified")
            case "end_session":
                fields["verification_status"] = .init(type: "string", description: "Derived required-check status")
                fields["verification"] = .init(type: "object", description: "Per-check outcomes and evidence")
                fields["recording_health"] = .init(
                    type: "string",
                    description: "saved, failed, pending, unknown, or disabled"
                )
            case "get_session_report":
                fields["artifactSnapshot"] = .init(type: "object", description: "Installed session-owned artifact")
                fields["verification"] = .init(type: "object", description: "Per-check outcomes and evidence")
                fields["verificationMetrics"] = .init(type: "object", description: "Measured host costs")
                fields["startup"] = .init(type: "object", description: "Startup state")
                fields["recording_health"] = .init(
                    type: "string",
                    description: "saved, failed, pending, unknown, or disabled"
                )
                fields["launchArguments"] = .init(type: "array", description: "Redacted launch arguments")
                fields["launchEnvironment"] = .init(type: "object", description: "Redacted launch environment")
                fields["testName"] = .init(type: "string", description: "Test name")
                fields["provenance"] = .init(type: "object", description: "Where the session came from")
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
        // Silently ignoring a start point leaves a swipe centred on the screen, which looks like it ran.
        if name == "swipe_in_direction", arguments["from_x"] == nil, arguments["from_y"] == nil,
           arguments["x"] != nil || arguments["y"] != nil {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "swipe_in_direction takes from_x/from_y for a start point; x and y are not arguments."
            )
        }
        try Self.validateSchema(name: name, arguments: arguments)
        try Self.validateSemantics(name: name, arguments: arguments)
        if let runID = arguments["run_id"], UUID(uuidString: runID) == nil {
            throw Self.invalidArgument("run_id", example: "run_id=550e8400-e29b-41d4-a716-446655440000 (UUID required)")
        }
        let nonnegative = [
            "timeout_ms", "duration_ms", "character_count", "offset", "settle_timeout_ms", "hittable_timeout_ms",
            "effect_timeout_ms", "hold_ms"
        ]
        let coordinates = ["x", "y", "from_x", "from_y", "to_x", "to_y", "latitude", "longitude", "distance", "scale"]
        for key in nonnegative + coordinates {
            guard let raw = arguments[key] else { continue }
            guard let number = Double(raw), number.isFinite, abs(number) <= 1_000_000_000,
                  !nonnegative.contains(key) || Int(raw).map({ (0 ... 3_600_000).contains($0) }) == true,
                  // A screenshot scale shrinks (0, 1]; a pinch scale zooms either way and the executor checks it.
                  key != "scale" || name == "pinch" || (number > 0 && number <= 1),
                  key != "latitude" || abs(number) <= 90,
                  key != "longitude" || abs(number) <= 180 else {
                throw Self.invalidArgument(key, example: "\(key)=1")
            }
        }
        let booleanKeys = [
            "record_speech", "return_image", "labeled_only", "include_offline", "all_frames", "force",
            "check_hittable", "check_effect", "activate", "fresh_install", "precondition", "expect_absent"
        ]
        for key in booleanKeys {
            if let raw = arguments[key], boolArgument(raw) == nil {
                throw Self.invalidArgument(key, example: "\(key)=true")
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
            "device_health",
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
            "drag",
            "pinch",
            "press_back",
            "assert_visible",
            "assert_absent",
            "assert_value",
            "assert_selected", "assert_checked", "assert_state_description",
            "assert_enabled",
            "list_devices",
            "run_steps"
        ])
        if ["session_startup_status", "get_capabilities", "get_verification_report", "get_run_telemetry"]
            .contains(name) {
            return true
        }
        switch self {
        case .all: return true
        case .drive:
            let management = [
                "start_session",
                "end_session",
                "companion_warm",
                "companion_status",
                "reset_companion",
                "session_startup_status"
            ]
            return driving.contains(name) || management.contains(name)
        case .record: return driving.contains(name) || lifecycle.contains(name)
        case .audit: return Set(AuditTools.names + AssistantTools.names).contains(name) || lifecycle.contains(name)
        }
    }
}

// swiftlint:enable multiline_arguments
