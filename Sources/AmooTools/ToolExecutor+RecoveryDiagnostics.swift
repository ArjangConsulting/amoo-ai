// swiftlint:disable multiline_arguments
import AmooCore
import Foundation

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
        var rootNote: String?
        fields["observation_status"] = .string(empty ? "empty_observation" : "selector_miss")
        fields["navigation_status"] = .string("unassessed")
        fields["recovery"] = .array([
            .string("If an available_controls entry is the intended control, retry with its selector directly."),
            .string(
                "Otherwise confirm target identity with find_elements (stable id or scoped contains_text, limit=12)."
            ),
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
            if arguments["parent_id"] == nil, Self.isOnlyTheRoot(candidates) {
                fields["only_root_element"] = .bool(true)
                rootNote = Self.onlyRootNote(candidates)
            }
            fields["available_controls"] = .array(
                Self.nearbyCandidates(candidates, arguments: arguments).map(Self.availableControl)
            )
        }
        if missing {
            fields["selector_hint"] = .string(
                "Accessible text may be split across word-level actions; use the reported roles and exact labels."
            )
        }
        var result = original
        result.structuredContent = .object(fields)
        if let rootNote {
            result.content += "\n\(rootNote)"
        }
        return result
    }

    private static func availableControl(_ element: ElementInfo) -> Value {
        var control: [String: Value] = [
            "id": .string(element.id), "label": .string(String(element.label.prefix(120))),
            "role": .string(element.type?.rawValue ?? "unknown"), "enabled": .bool(element.isEnabled),
            // Ready to retry with: the stable id when there is one, otherwise the exact label.
            "selector": .object(element.id.isEmpty ? ["label": .string(element.label)] : ["id": .string(element.id)])
        ]
        if let point = element.hitPoint ?? element.frame?.centre {
            control["x"] = .double((point.x * 10).rounded() / 10)
            control["y"] = .double((point.y * 10).rounded() / 10)
        }
        return .object(control)
    }

    /// Whether a whole-screen read found nothing but the root: at most one named element, and it not
    /// a control, besides unnamed containers. A sheet another process draws over the app ("Save
    /// Password?" on iOS) can leave just the application element and an unnamed full-screen container,
    /// and reporting that as a plain selector miss hid why.
    static func isOnlyTheRoot(_ elements: [ElementInfo]) -> Bool {
        let named = elements.filter { !isUnnamedContainer($0) }
        guard named.count <= 1 else { return false }
        return named.first.map { $0.type == nil || $0.type == .other } ?? true
    }

    private static func isUnnamedContainer(_ element: ElementInfo) -> Bool {
        element.id.isEmpty && element.label.trimmingCharacters(in: .whitespaces).isEmpty
            && (element.type == nil || element.type == .other)
    }

    static func onlyRootNote(_ elements: [ElementInfo]) -> String {
        let root = elements.first { !isUnnamedContainer($0) }
        let name = root.map { $0.label.isEmpty ? $0.id : $0.label }.map { " ('\($0)')" } ?? ""
        return "The accessibility tree holds only the application element\(name), so something it cannot show"
            + " may cover the app, such as a system sheet another process draws (iOS \"Save Password?\" after a"
            + " sign-in). dismiss_system_dialogs=true finds and answers such a prompt in the process that draws it."
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
