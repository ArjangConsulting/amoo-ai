import AmooCore
import Foundation

private extension AuditRule {
    func coverage(_ sufficient: Bool, missing: String) -> AuditRuleEvaluation {
        AuditRuleEvaluation(
            ruleID: metadata.id,
            status: sufficient ? .evaluated : .insufficientEvidence,
            reason: sufficient ? "Evaluated the observed current-screen heuristic only." : missing
        )
    }

    func elementCoverage(_ elements: [ElementInfo]) -> AuditRuleEvaluation {
        coverage(
            !elements.isEmpty && elements.allSatisfy { $0.type != nil },
            missing: "Requires a nonempty element capture with known element types; empty capture is not absence."
        )
    }

    func hierarchyCoverage(_ root: ViewNode) -> AuditRuleEvaluation {
        var pending: [(ViewNode, Int)] = [(root, 0)]
        var count = 0
        while let (node, depth) = pending.popLast() {
            count += 1
            guard depth < 256, count <= 10000 else {
                return coverage(false, missing: "Hierarchy exceeds the bounded traversal; coverage is incomplete.")
            }
            pending += node.children.map { ($0, depth + 1) }
        }
        return coverage(
            root.type != nil || !root.children.isEmpty,
            missing: "Requires a populated hierarchy; an empty placeholder cannot establish coverage."
        )
    }
}

public extension DebugBuildExposureRule {
    func evidenceCoverage(_ input: AuditInput) -> AuditRuleEvaluation {
        coverage(
            !input.screenContext.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            missing: "Requires captured screen text; absence of debug indicators cannot certify a production build."
        )
    }
}

public extension InsecureTextFieldRule {
    func evidenceCoverage(_ input: AuditInput) -> AuditRuleEvaluation {
        elementCoverage(input.elements)
    }
}

public extension ErrorStateHandlingRule {
    func evidenceCoverage(_ input: AuditInput) -> AuditRuleEvaluation {
        elementCoverage(input.elements + input.interactableElements)
    }
}

public extension NavigationDeadEndRule {
    func evidenceCoverage(_ input: AuditInput) -> AuditRuleEvaluation {
        hierarchyCoverage(input.hierarchy)
    }
}

public extension MissingAccessibilityLabelRule {
    func evidenceCoverage(_ input: AuditInput) -> AuditRuleEvaluation {
        elementCoverage(input.interactableElements)
    }
}

public extension SmallTapTargetRule {
    func evidenceCoverage(_ input: AuditInput) -> AuditRuleEvaluation {
        coverage(
            ["points", "dp"].contains(input.geometryUnit)
                && !input.interactableElements.isEmpty && input.interactableElements.allSatisfy {
                    guard let frame = $0.frame else { return false }
                    return frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
                },
            missing: "Requires normalized points/dp and finite positive bounds for all interactables;"
                + " hit regions unverified."
        )
    }
}

public extension MissingStableIdentifierRule {
    func evidenceCoverage(_ input: AuditInput) -> AuditRuleEvaluation {
        elementCoverage(input.interactableElements)
    }
}

public extension HierarchyDepthRule {
    func evidenceCoverage(_ input: AuditInput) -> AuditRuleEvaluation {
        hierarchyCoverage(input.hierarchy)
    }
}
