public struct AuditEngine: Sendable {
    private let rules: [any AuditRule]

    public init(rules: [any AuditRule], lowConfidenceThreshold _: Double = 0.5) {
        self.rules = rules
    }

    public func run(_ input: AuditInput) async throws -> AuditReport {
        var collected: [AuditFinding] = []
        var evaluations: [AuditRuleEvaluation] = []
        for rule in rules {
            let coverage = input.evidenceProblems.isEmpty ? rule.evidenceCoverage(input)
                : AuditRuleEvaluation(
                    ruleID: rule.metadata.id,
                    status: .insufficientEvidence,
                    reason: input.evidenceProblems.joined(separator: "; ")
                )
            guard coverage.status != .notEvaluated else {
                evaluations.append(coverage)
                continue
            }
            do {
                try Task.checkCancellation()
                try await collected.append(contentsOf: rule.evaluate(input))
                evaluations.append(coverage)
            } catch {
                evaluations.append(AuditRuleEvaluation(
                    ruleID: rule.metadata.id,
                    status: .executionError,
                    reason: "Rule execution failed: \(error)"
                ))
            }
        }
        return AuditReport(appID: input.appID, findings: collected, evaluations: evaluations)
    }
}
