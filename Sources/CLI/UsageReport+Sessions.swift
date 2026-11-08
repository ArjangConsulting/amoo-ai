import Foundation
import TestSession

/// Retry patterns from recorded sessions and generated-test health from compiled plans.
enum UsageSessionReader {
    static let inspectionTools: Set = [
        "find_elements", "describe_screen", "get_view_hierarchy", "take_screenshot", "get_screen_context",
        "current_app", "find_element_by_description"
    ]

    static func aggregate(_ reports: [SessionReport], into report: inout UsageReport) {
        var retries = report.retries
        retries.sessions = reports.count
        var errors: [String: UsageReport.ErrorCount] = [:]
        for session in reports {
            let actions = session.actions
            for (index, action) in actions.enumerated() {
                if index > 0, actions[index - 1].toolName == action.toolName,
                   arguments(actions[index - 1]) == arguments(action) {
                    retries.identicalConsecutive[action.toolName, default: 0] += 1
                }
                guard action.isError else { continue }
                let message = UsageStatistics.normalizedMessage(action.result)
                let key = action.toolName + "|" + message
                errors[key, default: UsageReport.ErrorCount(tool: action.toolName, message: message, count: 0)]
                    .count += 1
                let lowered = action.result.lowercased()
                if lowered.contains("no element matched") || lowered.contains("element_not_found") {
                    retries.selectorMisses += 1
                }
                if lowered.contains("transient failure") || lowered.contains("unavailable:") {
                    retries.transportFailures += 1
                }
                if lowered.contains("time budget") || lowered.contains("timed out") || lowered.contains("deadline") {
                    retries.timeouts += 1
                }
                let following = actions[(index + 1)...].prefix(3)
                if let next = following.first, inspectionTools.contains(next.toolName),
                   !inspectionTools.contains(action.toolName) {
                    retries.failedThenInspected[action.toolName, default: 0] += 1
                }
                if following.contains(where: { $0.toolName == action.toolName }) {
                    retries.failedThenRetried[action.toolName, default: 0] += 1
                }
            }
        }
        report.retries = retries
        report.errors = errors.values
            .sorted { $0.count > $1.count }
            .prefix(20).map(\.self)
    }

    private static func arguments(_ action: SessionAction) -> [String: String] {
        action.arguments.filter { $0.key != "session_id" && $0.key != "run_id" }
    }

    // MARK: - Codegen health

    /// Categories that put a generated test's fidelity or stability at risk.
    static let riskCategories: Set = [
        "locale_dependent_selector", "approximate_selector", "observation_approximated",
        "final_mutation_unasserted", "redacted_value", "action_excluded"
    ]

    /// Reads each session's `plan.json` and counts compiler warnings by category. Plans written
    /// before categories existed are classified from the warning text.
    static func aggregatePlans(root: URL, sessionIDs: Set<String>?, into report: inout UsageReport) {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var health = UsageReport.CodegenHealth()
        var risky = 0
        for entry in entries where sessionIDs?.contains(entry.lastPathComponent) ?? true {
            let url = entry.appending(path: "plan.json")
            guard let data = try? Data(contentsOf: url),
                  let plan = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            health.plans += 1
            let steps = (plan["steps"] as? [Any])?.count ?? 0
            health.steps += steps
            if steps > 0 {
                health.plansWithSteps += 1
            }
            let compiled = plan["compiledPlan"] as? [String: Any]
            for warning in compiled?["warnings"] as? [[String: Any]] ?? [] {
                let category = classify(warning)
                health.warnings[category, default: 0] += 1
                if steps > 0, riskCategories.contains(category) {
                    risky += 1
                }
            }
        }
        health.riskPerPlan = health.plansWithSteps == 0 ? 0
            : (Double(risky) / Double(health.plansWithSteps) * 100).rounded() / 100
        report.codegen = health
        report.sources.plans = health.plans
    }

    static func classify(_ warning: [String: Any]) -> String {
        let reason = (warning["reason"] as? String ?? "").lowercased()
        // Text matches come first: older plans carry only a broad category, if any.
        let patterns: [(String, String)] = [
            ("depends on locale", "locale_dependent_selector"),
            ("approximate selector", "approximate_selector"),
            ("observation compiled into", "observation_approximated"),
            ("compiled a pre-transition inspection", "observation_approximated"),
            ("final mutation has no following", "final_mutation_unasserted"),
            ("redacted value", "redacted_value"),
            ("no studio tool equivalent", "action_excluded"),
            ("failed exploratory action", "failed_action_omitted"),
            ("diagnostic", "diagnostic_omitted"),
            ("inspection", "inspection_omitted")
        ]
        if let match = patterns.first(where: { reason.contains($0.0) }) {
            return match.1
        }
        return warning["category"] as? String ?? (warning["kind"] as? String).map { "kind_\($0)" } ?? "other"
    }
}
