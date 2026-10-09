import AmooCore
import Foundation
import MCP

extension DriverToolExecutor {
    func executeAccessibilityInspection(
        driver: any PlatformDriver, arguments: [String: String], toolName: String
    ) async throws -> ToolResult {
        guard let appID = arguments["app_id"], !appID.isEmpty else {
            throw ToolExecutionError(code: "invalid_argument", message: "Requires app_id")
        }
        if let id = arguments["session_id"], let session = await sessionManager?.session(id), session.appID != appID {
            throw ToolExecutionError(
                code: "wrong_app",
                message: "Inspection target must match the session's app identity"
            )
        }
        let current = try await driver.currentApp()
        guard current.bundleID == appID else {
            throw ToolExecutionError(code: "wrong_app", message: "Inspection target is not the frontmost app")
        }
        let operation = toolName == "test_voiceover" ? "voiceOver" : "nativeAudit"
        let categories = arguments["categories"]
            .map {
                $0.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            ?? AccessibilityInspectionOptions.auditCategories.sorted()
        let steps: Int
        if let value = arguments["steps"] {
            guard let count = Int(value) else {
                throw ToolExecutionError(code: "invalid_argument", message: "steps must be an integer")
            }
            steps = count
        } else {
            steps = 5
        }
        let direction = arguments["direction"] ?? "forward"
        try AccessibilityInspectionOptions.validate(
            operation: operation, categories: categories, steps: steps, direction: direction
        )
        let phases = try inspectionPhases(arguments: arguments, operation: operation)
        var report = if phases.isEmpty {
            try await driver.inspectAccessibility(
                appID: appID, operation: operation, categories: categories, steps: steps, direction: direction
            )
        } else {
            try await driver.inspectVoiceOver(appID: appID, phases: phases)
        }
        if report.requestedChecks.isEmpty {
            report.requestedChecks = operation == "nativeAudit" ? categories
                : (phases.isEmpty ? [VoiceOverPhase(steps: steps, direction: direction)] : phases).indices.map {
                    "traversal.phase.\($0)"
                }
            report.notEvaluatedReasons = Dictionary(report.requestedChecks.map {
                ($0, report.error ?? "Companion did not supply evaluated coverage")
            }, uniquingKeysWith: { first, _ in first })
        }
        report = try await inspectionProvenance(report, driver: driver, arguments: arguments, appID: appID)
        return try ToolResult(
            content: "\(report.provider): execution=\(report.executionStatus), verdict=\(report.verdict),"
                + " cleanup=\(report.cleanupStatus). \(report.issues.count) issue(s),"
                + " \(report.utterances.count) observed utterance(s). \(report.error ?? "")",
            isError: report.executionStatus != "succeeded" || ["failed", "unknown"].contains(report.cleanupStatus),
            structuredContent: Value(report)
        )
    }

    private func inspectionPhases(arguments: [String: String], operation: String) throws -> [VoiceOverPhase] {
        if let raw = arguments["phases"] {
            guard operation == "voiceOver", arguments["steps"] == nil, arguments["direction"] == nil,
                  let decoded = try? JSONDecoder().decode([VoiceOverPhase].self, from: Data(raw.utf8)) else {
                throw ToolExecutionError(
                    code: "invalid_argument",
                    message: "phases requires a VoiceOver JSON array;"
                        + " omit steps and direction when providing phases"
                )
            }
            try VoiceOverPhase.validate(decoded)
            return decoded
        }
        return []
    }
}
