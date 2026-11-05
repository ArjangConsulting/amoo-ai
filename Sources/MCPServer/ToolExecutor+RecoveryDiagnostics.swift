// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
import MCP

private struct RankedCandidate {
    let index: Int
    let element: ElementInfo
    let score: Int
}

extension DriverToolExecutor {
    func diagnoseSelectorMiss(
        _ original: ToolResult, tool: String, arguments: [String: String]
    ) async -> ToolResult {
        var fields = original.structuredContent?.objectValue ?? [:]
        let scoped = ["id", "label", "contains_text", "description", "parent_id"].contains { arguments[$0] != nil }
        let missing = fields["code"] == .string("element_not_found")
            || fields["failure_kind"] == .string("selector_miss")
            || (tool == "assert_visible" && fields["passed"] == .bool(false) && fields["query"] != nil)
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
            try await self.findScopedElements(
                ElementSelector(parentSelector: arguments["parent_id"].map {
                    ParentSelector.selector(ElementSelector(id: $0))
                }), driver: driver, appID: self.queryScopeAppID(arguments: arguments, driver: driver)
            )
        }) {
            fields["available_controls"] = .array(Self.nearbyCandidates(candidates, arguments: arguments).map {
                .object([
                    "id": .string($0.id), "label": .string(String($0.label.prefix(120))),
                    "role": .string($0.type?.rawValue ?? "unknown"), "enabled": .bool($0.isEnabled)
                ])
            })
        }
        if missing {
            fields["selector_hint"] = .string(
                "Accessible text may be split across word-level actions; use the reported roles and exact labels."
            )
        }
        var result = original
        result.structuredContent = .object(fields)
        return result
    }

    static func nearbyCandidates(_ candidates: [ElementInfo], arguments: [String: String]) -> [ElementInfo] {
        let query = ["id", "label", "contains_text", "description"].compactMap { arguments[$0] }.joined(separator: " ")
        let words = Set(query.lowercased().components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty })
        var scored: [RankedCandidate] = []
        for (index, element) in candidates.enumerated() where element.isVisible {
            let text = (element.id + " " + element.label).lowercased()
            let pieces = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            let tokens = Set(pieces.filter { !$0.isEmpty })
            scored.append(RankedCandidate(index: index, element: element, score: words.intersection(tokens).count))
        }
        let ranked = scored.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
        }
        return ranked.prefix(8).map(\.element)
    }
}

// swiftlint:enable multiline_arguments
