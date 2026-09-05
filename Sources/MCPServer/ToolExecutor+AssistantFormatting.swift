import AmooCore
import AuditEngine
import Foundation
import MCP
import TestSession

extension DriverToolExecutor {
    func parseDirection(_ value: String) -> Direction? {
        switch value.lowercased() {
        case "up": .up
        case "down": .down
        case "left": .left
        case "right": .right
        default: nil
        }
    }

    func formatSuggestionReport(_ report: TestActionSuggestionReport) -> String {
        var lines = [
            "Screen intent: \(report.screenIntent)",
            "Confidence: \(report.confidence)",
            "",
            "Suggested actions:"
        ]

        for action in report.suggestedActions.sorted(by: { $0.priority < $1.priority }) {
            lines.append("\(action.priority). \(action.action) - \(action.reason)")
        }

        lines.append("")
        lines.append("Accessibility issues:")
        if report.accessibilityIssues.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: report.accessibilityIssues.map { "- \($0)" })
        }

        lines.append("")
        lines.append("Developer feedback:")
        if report.developerFeedback.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: report.developerFeedback.map { "- \($0)" })
        }

        return lines.joined(separator: "\n")
    }

    func formatAITestabilityReport(_ report: AITestabilityReport) -> String {
        var lines = [
            "AI testability: \(report.confidence)",
            "Screen summary: \(report.screenSummary)",
            "Interactable elements: \(report.interactableCount)",
            "",
            "Diagnostics:"
        ]

        if report.diagnostics.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: report.diagnostics.map { "- \($0)" })
        }

        if !report.elementsWithIssues.isEmpty {
            lines.append("")
            lines.append("Elements with accessibility issues (\(report.elementsWithIssues.count)):")
            for issue in report.elementsWithIssues {
                let typeStr = issue.type.map { " [\($0)]" } ?? ""
                let idStr = issue.id.isEmpty ? "(no id)" : issue.id
                let labelStr = issue.label.isEmpty ? "(no label)" : "\"\(issue.label)\""
                let frameStr = issue.frame.map { frame in
                    " at (\(Int(frame.x)), \(Int(frame.y))) \(Int(frame.width))×\(Int(frame.height))pt"
                } ?? ""
                lines.append("  \(idStr)\(typeStr) \(labelStr)\(frameStr) — \(issue.issue)")
            }
        }

        lines.append("")
        lines.append("Developer feedback:")
        lines.append(contentsOf: report.developerFeedback.map { "- \($0)" })

        return lines.joined(separator: "\n")
    }

    func filterAppRelevantElements(_ elements: [ElementInfo]) -> [ElementInfo] {
        elements.filter { element in
            guard element.isVisible, element.isEnabled else { return false }
            return !isLikelySystemElement(element)
        }
    }

    func isLikelySystemElement(_ element: ElementInfo) -> Bool {
        // Labels are app-owned content, never a reliable process boundary. Query scope selects
        // app/system UI; do not hide controls in clock, battery, or settings applications.
        false
    }

    func collectAccessibilityDiagnostics(
        allElements: [ElementInfo],
        interactableElements: [ElementInfo]
    ) -> [String] {
        var diagnostics: [String] = []

        let unlabeledInteractables = interactableElements.filter { preferredElementName(
            label: $0.label,
            id: normalizedElementID($0.id)
        ) == nil
        }
        if !unlabeledInteractables.isEmpty {
            diagnostics
                .append(
                    "\(unlabeledInteractables.count) interactable element(s) are missing a meaningful"
                        + " accessibility label or identifier."
                )
        }

        let genericLabels = interactableElements.filter {
            let label = $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["button", "image", "text field", "text", "label", "item", "view"].contains(label)
        }
        if !genericLabels.isEmpty {
            diagnostics
                .append(
                    "\(genericLabels.count) interactable element(s) use generic labels such as 'Button'"
                        + " or 'Text field'."
                )
        }

        let duplicateLabels = Dictionary(grouping: interactableElements) {
            $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let duplicatedNames = duplicateLabels.filter { key, value in !key.isEmpty && value.count > 1 }
        if !duplicatedNames.isEmpty {
            let names = duplicatedNames.keys.sorted().prefix(3).joined(separator: ", ")
            diagnostics.append("Duplicate interactable labels detected: \(names).")
        }

        let hiddenInteractables = allElements.filter { !$0.isVisible && $0.isEnabled && !isLikelySystemElement($0) }
        if !hiddenInteractables.isEmpty {
            diagnostics
                .append(
                    "\(hiddenInteractables.count) enabled element(s) are hidden, which can confuse"
                        + " screen understanding."
                )
        }

        if interactableElements.isEmpty {
            diagnostics.append("No app-relevant interactable elements were exposed after filtering system UI.")
        }

        return diagnostics
    }

    func collectElementA11yIssues(
        allElements: [ElementInfo],
        interactableElements: [ElementInfo]
    ) -> [ElementA11yIssue] {
        var issues: [ElementA11yIssue] = []

        let genericLabelSet: Set = ["button", "image", "text field", "text", "label", "item", "view"]

        for element in interactableElements {
            let typeLabel = element.type?.rawValue

            if preferredElementName(label: element.label, id: normalizedElementID(element.id)) == nil {
                issues.append(ElementA11yIssue(
                    id: element.id,
                    label: element.label,
                    type: typeLabel,
                    issue: "missing_label: no meaningful accessibility label or stable identifier",
                    frame: element.frame
                ))
                continue
            }

            let normalizedLabel = element.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if genericLabelSet.contains(normalizedLabel) {
                issues.append(ElementA11yIssue(
                    id: element.id,
                    label: element.label,
                    type: typeLabel,
                    issue: "generic_label: label '\(element.label)' does not describe the element's purpose",
                    frame: element.frame
                ))
            }
        }

        let labelGroups = Dictionary(grouping: interactableElements) {
            $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        for (key, group) in labelGroups where !key.isEmpty && group.count > 1 {
            for element in group {
                let alreadyTagged = issues.contains { $0.id == element.id && $0.label == element.label }
                if !alreadyTagged {
                    issues.append(ElementA11yIssue(
                        id: element.id,
                        label: element.label,
                        type: element.type?.rawValue,
                        issue: "duplicate_label: label '\(element.label)' is shared by \(group.count) elements",
                        frame: element.frame
                    ))
                }
            }
        }

        let hiddenEnabled = allElements.filter { !$0.isVisible && $0.isEnabled && !isLikelySystemElement($0) }
        for element in hiddenEnabled {
            issues.append(ElementA11yIssue(
                id: element.id,
                label: element.label,
                type: element.type?.rawValue,
                issue: "hidden_but_enabled: element is enabled but not visible in the accessibility tree",
                frame: element.frame
            ))
        }

        return issues
    }

    func developerFeedback(for diagnostics: [String]) -> [String] {
        var feedback: [String] = []

        for diagnostic in diagnostics {
            let lowered = diagnostic.lowercased()
            if lowered.contains("missing a meaningful accessibility label") {
                feedback
                    .append(
                        "Add explicit accessibility labels or stable identifiers to every tappable"
                            + " control and input."
                    )
            }
            if lowered.contains("generic labels") {
                feedback
                    .append(
                        "Replace generic labels like 'Button' or 'Text field' with semantic names"
                            + " that reflect the user-visible purpose."
                    )
            }
            if lowered.contains("duplicate interactable labels") {
                feedback
                    .append(
                        "Make repeated controls distinguishable with unique accessibility labels,"
                            + " values, or identifiers."
                    )
            }
            if lowered.contains("enabled element"), lowered.contains("hidden") {
                feedback
                    .append(
                        "Ensure hidden elements are not exposed as enabled accessibility nodes unless"
                            + " they are intentionally interactive."
                    )
            }
            if lowered.contains("no app-relevant interactable elements") {
                feedback
                    .append(
                        "Expose the primary CTA, form fields, and navigation targets through"
                            + " accessibility so AI can identify the main flow."
                    )
            }
        }

        if feedback.isEmpty {
            feedback
                .append(
                    "Keep primary actions, inputs, and navigation controls clearly labeled to"
                        + " preserve high-confidence AI suggestions."
                )
        }

        var seen = Set<String>()
        return feedback.filter { seen.insert($0).inserted }
    }

    func enrichedScreenContext(
        context: ScreenContext,
        allElements: [ElementInfo],
        interactableElements: [ElementInfo],
        hierarchy: ViewNode
    ) -> ScreenContext {
        let title = context.screenTitle?.isEmpty == false
            ? context.screenTitle
            : inferredScreenTitle(from: allElements, hierarchy: hierarchy)

        let primaryTargets = interactableElements.prefix(3).compactMap { preferredElementName(
            label: $0.label,
            id: normalizedElementID($0.id)
        )
        }
        let visibleText = allElements
            .filter { $0.type == .staticText }
            .prefix(4)
            .compactMap { preferredElementName(label: $0.label, id: nil) }

        let summaryParts = [
            title.map { "title=\($0)" },
            !primaryTargets.isEmpty ? "primary_actions=\(primaryTargets.joined(separator: ", "))" : nil,
            !visibleText.isEmpty ? "visible_text=\(visibleText.joined(separator: ", "))" : nil,
            context.summary.isEmpty ? nil : context.summary
        ].compactMap(\.self)

        return ScreenContext(
            summary: summaryParts.joined(separator: " | "),
            interactableCount: interactableElements.count,
            screenTitle: title
        )
    }

    func inferredScreenTitle(from elements: [ElementInfo], hierarchy: ViewNode) -> String? {
        if let textTitle = elements
            .first(where: { $0.type == .staticText && !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })?.label,
            !textTitle.isEmpty {
            return textTitle
        }

        if !hierarchy.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return hierarchy.label
        }

        return nil
    }

    func normalizedElementID(_ id: String) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        let genericPatterns = ["button", "text", "label", "image", "view", "cell"]
        if genericPatterns
            .contains(where: { lowered == $0 || lowered.hasPrefix("\($0)") && lowered.count <= $0.count + 2 }) {
            return nil
        }
        return trimmed
    }
}
