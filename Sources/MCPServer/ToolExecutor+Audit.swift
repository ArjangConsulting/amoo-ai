// swiftlint:disable multiline_arguments
import AmooCore
import AuditEngine
import Foundation
import MCP
import TestSession

extension DriverToolExecutor {
    func executeAudit(
        driver: any PlatformDriver,
        arguments: [String: String],
        rulePacks: [any AuditRule]
    ) async throws -> ToolResult {
        guard let appID = arguments["app_id"] else {
            return .error("Missing required argument: app_id")
        }

        let selectedRules: [any AuditRule] = if let packNames = arguments["rule_packs"] {
            try parseRulePacks(packNames)
        } else {
            rulePacks
        }

        if let threshold = arguments["fail_on"], !["critical", "high", "medium", "low", "info"].contains(threshold) {
            throw ToolExecutionError(code: "invalid_argument", message: "Unknown audit severity.")
        }
        let current = try await driver.currentApp()
        guard current.bundleID == appID else {
            throw ToolExecutionError(code: "wrong_app", message: "Audit target is not the frontmost app.")
        }
        let observation = try await driver.observeScreen(appID: appID)
        let after = try? await driver.currentApp()
        let geometry = try? await driver.elementGeometry()
        let platform = try? await driver.deviceInfo().platform
        // Without a density, Android frames stay in pixels and size heuristics decline to evaluate.
        let fallbackUnit = platform == .ios ? "points" : platform == .android ? "pixels" : "unknown"
        let normalize: ([ElementInfo]) -> [ElementInfo] = { elements in
            guard let geometry else { return elements }
            return elements.map { element in
                var copy = element
                copy.frame = element.frame.map(geometry.normalized)
                return copy
            }
        }
        let input = AuditInput(
            appID: appID, screenContext: observation.context, hierarchy: observation.hierarchy,
            elements: normalize(observation.elements),
            interactableElements: normalize(observation.interactableElements),
            evidenceProblems: after?.bundleID == appID ? [] : ["Foreground app changed during capture."],
            geometryUnit: geometry?.unit ?? fallbackUnit
        )

        let engine = AuditEngine(rules: selectedRules)
        let report = try await engine.run(input)

        return formatAuditReport(report, failOn: arguments["fail_on"])
    }

    func parseRulePacks(_ names: String) throws -> [any AuditRule] {
        let packs = names.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var rules: [any AuditRule] = []
        for pack in packs {
            switch pack {
            case "security": rules += RulePacks.security
            case "quality": rules += RulePacks.quality
            case "ux": rules += RulePacks.ux
            case "accessibility": rules += RulePacks.accessibility
            case "testability": rules += RulePacks.testability
            case "all": return RulePacks.all
            default: throw ToolExecutionError(code: "invalid_argument", message: "Unknown audit rule pack: \(pack)")
            }
        }
        return rules.isEmpty ? RulePacks.all : rules
    }

    func formatAuditReport(_ report: AuditReport, failOn: String?) -> ToolResult {
        if report.findings.isEmpty {
            return ToolResult(
                content: "No findings in the inspected screen for \(report.appID). See evidence coverage.",
                isError: report.executionFailed,
                structuredContent: auditStructuredContent(report, failOn: failOn, failed: false)
            )
        }

        var lines = ["Audit report for \(report.appID): \(report.findings.count) finding(s)\n"]

        let sorted = report.findings.sorted { severityOrder($0.severity) < severityOrder($1.severity) }
        for finding in sorted {
            lines.append("[\(finding.severity.rawValue.uppercased())] \(finding.summary)")
            lines
                .append("  Rule: \(finding.ruleID) | Confidence: \(String(format: "%.0f%%", finding.confidence * 100))")
            lines.append("  Fix: \(finding.remediation)")
            lines.append("")
        }

        let isFailure: Bool
        if let threshold = failOn {
            let thresholdOrder = severityOrder(parseSeverity(threshold))
            isFailure = sorted.contains { severityOrder($0.severity) <= thresholdOrder }
        } else {
            isFailure = false
        }

        return ToolResult(
            content: lines.joined(separator: "\n"), isError: isFailure || report.executionFailed,
            structuredContent: auditStructuredContent(
                report,
                failOn: failOn,
                failed: isFailure
            )
        )
    }

    private func auditStructuredContent(_ report: AuditReport, failOn: String?, failed: Bool) -> Value {
        var fields = (try? Value(report))?.objectValue ?? [:]
        let complete = !report.evaluations.isEmpty && report.evaluations.allSatisfy { $0.status == .evaluated }
        fields["executionStatus"] = .string(report.executionFailed ? "failed" : "succeeded")
        fields["verdict"] = .string(failed ? "fail" : failOn != nil && complete ? "pass" : "notAssessed")
        fields["cleanupStatus"] = .string("notRequired")
        fields["coverage"] = .object([
            "requested": .array(report.evaluations.map { .string($0.ruleID) }),
            "evaluated": .array(report.evaluations.filter { $0.status == .evaluated }.map { .string($0.ruleID) }),
            "notEvaluated": .object(Dictionary(report.evaluations.filter { $0.status != .evaluated }.map {
                ($0.ruleID, Value.string($0.reason))
            }, uniquingKeysWith: { first, _ in first })),
            "truncated": .bool(false)
        ])
        return .object(fields)
    }

    func severityOrder(_ severity: Severity) -> Int {
        switch severity {
        case .critical: 0
        case .high: 1
        case .medium: 2
        case .low: 3
        case .info: 4
        }
    }

    func parseSeverity(_ value: String) -> Severity {
        switch value.lowercased() {
        case "critical": .critical
        case "high": .high
        case "medium": .medium
        case "low": .low
        case "info": .info
        default: .high
        }
    }
}

// swiftlint:enable multiline_arguments
