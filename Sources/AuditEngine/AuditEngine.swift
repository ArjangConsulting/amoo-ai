public struct AuditEngine: Sendable {
    private let rules: [any AuditRule]
    private let lowConfidenceThreshold: Double

    public init(rules: [any AuditRule], lowConfidenceThreshold: Double = 0.5) {
        self.rules = rules
        self.lowConfidenceThreshold = lowConfidenceThreshold
    }

    public func run(_ input: AuditInput) async throws -> AuditReport {
        var collected: [AuditFinding] = []
        var evaluations: [AuditRuleEvaluation] = []
        for rule in rules {
            let coverage = rule.evidenceCoverage(input)
            evaluations.append(coverage)
            guard coverage.status == .evaluated else { continue }
            let findings = try await rule.evaluate(input)
            collected.append(contentsOf: findings.map { finding in
                guard finding.confidence < lowConfidenceThreshold else { return finding }
                return AuditFinding(
                    id: finding.id,
                    ruleID: finding.ruleID,
                    severity: .info,
                    confidence: finding.confidence,
                    summary: finding.summary,
                    remediation: finding.remediation,
                    evidence: finding.evidence,
                    tags: finding.tags
                )
            })
        }
        return AuditReport(appID: input.appID, findings: collected, evaluations: evaluations)
    }
}
