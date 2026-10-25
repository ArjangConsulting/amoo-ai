import Foundation

/// How a catalog groups tools. Assigned per tool family in `MCPServer`, except that every
/// `assert_*` tool is an assertion whichever family declares it.
public enum ToolCategory: String, Sendable, CaseIterable {
    case device
    case action
    case query
    case assertion
    case intent
    case assistant
    case audit
    case webView = "webview"
    case session
    case companion
    case batch
}

/// Catalog facts kept in one table instead of on each tool declaration: value hints for
/// enumerated arguments and the MCP read-only/destructive annotations.
///
/// Value hints list only canonical spellings the executor already accepts, so publishing an
/// exhaustive set as a JSON Schema `enum` never rejects an input that worked before.
enum ToolCatalogMetadata {
    private struct ValueHint {
        let tools: Set<String>?
        let property: String
        let values: [String]
        let exhaustive: Bool
    }

    private static let directions = ["up", "down", "left", "right"]

    private static let valueHints: [ValueHint] = [
        .init(
            tools: ["swipe_in_direction", "scroll", "scroll_to_element"],
            property: "direction",
            values: directions,
            exhaustive: true
        ),
        .init(tools: ["test_voiceover"], property: "direction", values: ["forward", "backward"], exhaustive: true),
        .init(tools: nil, property: "scope", values: ["app", "system"], exhaustive: true),
        .init(tools: nil, property: "platform", values: ["ios", "android"], exhaustive: true),
        .init(tools: ["get_view_hierarchy"], property: "format", values: ["full", "summary"], exhaustive: true),
        .init(tools: ["take_screenshot"], property: "format", values: ["png", "jpeg"], exhaustive: true),
        .init(tools: ["start_session"], property: "build_mode", values: ["auto", "reuse", "rebuild"], exhaustive: true),
        .init(tools: ["set_appearance"], property: "appearance", values: ["light", "dark"], exhaustive: true),
        .init(
            tools: ["set_orientation"],
            property: "orientation",
            values: ["portrait", "landscape_left", "landscape_right", "portrait_upside_down"],
            exhaustive: true
        ),
        .init(tools: ["webview_dom"], property: "mode", values: ["html", "a11y"], exhaustive: true),
        .init(
            tools: ["press_key"],
            property: "key",
            values: [
                "left_arrow", "right_arrow", "up_arrow", "down_arrow", "return", "escape", "tab",
                "space", "delete", "home", "end", "page_up", "page_down"
            ],
            exhaustive: false
        ),
        .init(
            tools: ["set_permission"],
            property: "permission",
            values: ["camera", "location", "photos"],
            exhaustive: false
        )
    ]

    /// Tools that observe without changing the device, the app, or server routing state that a
    /// later action depends on.
    private static let readOnlyTools: Set<String> = [
        "device_health", "find_elements", "get_view_hierarchy", "get_screen_context", "take_screenshot",
        "is_keyboard_visible", "current_app", "describe_screen", "suggest_test_actions",
        "analyze_ai_testability", "find_element_by_description", "assert_visible", "assert_enabled",
        "assert_absent", "assert_value", "assert_selected", "assert_checked", "assert_state_description",
        "assert_screen_changed",
        "audit_app",
        "audit_accessibility", "audit_security", "audit_accessibility_native", "list_devices",
        "list_apps", "companion_status", "session_startup_status", "list_sessions",
        "get_session_report", "compile_session_to_plan", "webview_dom"
    ]

    /// Tools that can destroy app or device state a user cannot get back by retrying.
    private static let destructiveTools: Set<String> = ["device_uninstall_app", "device_shutdown"]

    static func isReadOnly(_ tool: String) -> Bool {
        readOnlyTools.contains(tool)
    }

    static func apply(_ definition: ToolDefinition) -> ToolDefinition {
        var definition = definition
        if definition.name.hasPrefix("assert_") {
            definition.category = .assertion
        }
        definition.readOnly = readOnlyTools.contains(definition.name)
        definition.destructive = destructiveTools.contains(definition.name)
        for hint in valueHints where hint.tools?.contains(definition.name) ?? true {
            guard var property = definition.properties[hint.property] else { continue }
            property.values = hint.values
            property.valuesAreExhaustive = hint.exhaustive
            definition.properties[hint.property] = property
        }
        return definition
    }
}

extension ToolDefinition {
    func categorized(_ category: ToolCategory) -> ToolDefinition {
        var copy = self
        copy.category = category
        return copy
    }
}
