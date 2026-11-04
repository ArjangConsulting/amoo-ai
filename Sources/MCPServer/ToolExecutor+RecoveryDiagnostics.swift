import AmooCore
import MCP

extension DriverToolExecutor {
    func diagnoseSelectorMiss(
        _ original: ToolResult, tool: String, arguments: [String: String]
    ) async -> ToolResult {
        var fields = original.structuredContent?.objectValue ?? [:]
        let scoped = ["id", "label", "contains_text", "description", "parent_id"].contains { arguments[$0] != nil }
        let missing = fields["code"] == .string("element_not_found")
            || fields["last_observed"] == .string("no_match")
            || fields["last_observation_status"] == .string("no_match")
            || (tool == "find_elements" && fields["total"] == .int(0) && scoped)
        let empty = (tool == "get_screen_context" && (fields["screen_summary"] == .string("")
                || fields["semantic_readiness"] == .string("empty")))
            || (tool == "find_elements" && fields["total"] == .int(0) && !scoped)
        guard missing || empty, let driver = try? await resolveDriver(arguments: arguments) else { return original }
        let deadline = ContinuousClock.now + .seconds(2)
        fields["observation_status"] = .string(empty ? "empty_observation" : "selector_miss")
        fields["navigation_status"] = .string("unassessed")
        fields["recovery"] = .array([
            .string("Confirm target identity; query a stable id or scoped contains_text with find_elements limit=12."),
            .string("If the control is visible, inspect a saved screenshot and retry its actual semantic selector."),
            .string(
                "A content error or selector miss does not establish a navigation blocker. Test independent controls."
            )
        ])
        if let app = try? await OperationDeadline.read(until: deadline, operation: { try await driver.currentApp() }) {
            fields["foreground_app_id"] = .string(app.bundleID)
            fields["target_app_id"] = .string(app.targetBundleID)
        }
        if missing, let candidates = try? await OperationDeadline.read(until: deadline, operation: {
            try await driver.findElements(
                ElementSelector(),
                appID: self.queryScopeAppID(arguments: arguments, driver: driver)
            )
        }) {
            fields["available_controls"] = .array(candidates.filter { $0.isVisible && $0.isEnabled }.prefix(12).map {
                .object(["id": .string($0.id), "label": .string(String($0.label.prefix(120)))])
            })
        }
        var result = original
        result.structuredContent = .object(fields)
        return result
    }
}
