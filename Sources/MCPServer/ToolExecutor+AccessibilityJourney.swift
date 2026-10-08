import AmooCore
import Foundation
import MCP

extension DriverToolExecutor {
    func executeAccessibilityJourney(
        driver: any PlatformDriver, arguments: [String: String]
    ) async throws -> ToolResult {
        guard let appID = arguments["app_id"], !appID.isEmpty,
              let json = arguments["journey"], json.utf8.count <= 131_072 else {
            throw ToolExecutionError(
                code: "invalid_argument",
                message: "Requires app_id and journey JSON (at most 128 KiB)"
            )
        }
        let journey: AccessibilityJourney
        do {
            journey = try AccessibilityJourney.decodeJSON(json)
            try journey.validate()
        } catch {
            throw ToolExecutionError(code: "invalid_argument", message: "Invalid authored journey: \(error)")
        }
        if let id = arguments["session_id"], let session = await sessionManager?.session(id), session.appID != appID {
            throw ToolExecutionError(code: "wrong_app", message: "Journey target must match the session's app identity")
        }
        guard try await driver.currentApp().bundleID == appID else {
            throw ToolExecutionError(code: "wrong_app", message: "Journey target must be the frontmost app")
        }
        let captured = try await driver.inspectAccessibilityJourney(appID: appID, journey: journey)
        let report = try await inspectionProvenance(captured, driver: driver, arguments: arguments, appID: appID)
        return try ToolResult(
            content: "Journey \(journey.id): execution=\(report.executionStatus), verdict=\(report.verdict),"
                + " cleanup=\(report.cleanupStatus),"
                + " coverage=\(report.evaluatedChecks.count)/\(journey.requestedChecks.count).",
            isError: report.executionStatus != "succeeded" || report.verdict != "pass" || report
                .cleanupStatus != "restored",
            structuredContent: Value(report)
        )
    }
}
