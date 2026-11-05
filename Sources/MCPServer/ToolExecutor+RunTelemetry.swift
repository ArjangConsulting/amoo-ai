import Foundation
import MCP

extension DriverToolExecutor {
    func runIdentity(arguments: [String: String]) -> String {
        if let supplied = arguments["run_id"], UUID(uuidString: supplied) != nil {
            return supplied
        }
        return arguments["session_id"].flatMap { sessionRuns[$0] } ?? telemetryRunID
    }

    func executeRunTelemetry(arguments: [String: String]) async throws -> ToolResult {
        let runID = runIdentity(arguments: arguments)
        let report = await runTelemetry.snapshot(runID: runID, excluding: RunCallIdentity.current?.callID)
        return .success(
            "Run \(runID): \(report.totals["client_calls", default: 0]) calls across all attempts.",
            structuredContent: .object([
                "run_id": .string(runID), "metrics": .object(report.totals.mapValues(Value.int)),
                "session_ids": .array(report.sessions.map(Value.string)),
                "recording_health": .string(report.health), "model_token_usage": .null,
                "scope": .string("All requests with this run_id; excludes this report request."
                    + " Unfinished calls may still be running or may have been abandoned."
                    + " Model token usage is unavailable from device tools.")
            ])
        )
    }

    static func imagePixels(_ result: ToolResult) -> Int {
        let fields = result.structuredContent?.objectValue ?? [:]
        let width = fields["width_pixels"].flatMap { Double($0.description) } ?? 0
        let height = fields["height_pixels"].flatMap { Double($0.description) } ?? 0
        guard width > 0, height > 0, width * height <= Double(Int.max / 2) else { return 0 }
        return Int(width * height)
    }
}
