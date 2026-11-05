// swiftlint:disable multiline_arguments
import AmooCore
import Foundation
import MCP
import TestSession

enum VerificationTools {
    static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "get_verification_report",
            description: "Derived coverage and measured response bytes, call counts, image dimensions and timings."
                + " pass requires every requested check passed; fail requires an observed requirement failure;"
                + " partial means completed checks with missing coverage; blocked means none completed."
                + " Unsupported assertions and gesture dispatch are never proof. Available after end_session.",
            properties: ["session_id": .init(type: "string", description: "Managed session ID")],
            required: ["session_id"]
        ),
        ToolDefinition(
            name: "get_run_telemetry",
            description: "Aggregate calls, failed startup/recovery, unfinished requests, text payload,"
                + " image bytes and pixels across every session sharing a run_id. Model token usage is unavailable."
                + " Set run_id or AMOO_RUN_ID across processes; MCP sessions inherit it.",
            properties: ["session_id": .init(type: "string", description: "Optional session whose run to aggregate")]
        )
    ]
}

extension DriverToolExecutor {
    static func requestedChecks(_ source: String?) throws -> [String]? {
        guard let source else { return nil }
        guard let checks = try? JSONDecoder().decode([String].self, from: Data(source.utf8)),
              (1 ... 128).contains(checks.count), Set(checks).count == checks.count,
              checks.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 120 })
        else { throw ToolRequest.invalidArgument("checks", example: "checks=[\"navigation\",\"content\"]") }
        return checks
    }

    func validateCheck(arguments: [String: String]) async throws {
        guard let check = arguments["check_id"] else { return }
        guard let id = arguments["session_id"], let session = await sessionManager?.session(id),
              await session.verification?.checks.contains(where: { $0.id == check }) == true else {
            throw ToolRequest.invalidArgument("check_id", example: "Declare this ID in start_session checks first")
        }
    }

    func trackVerification(tool: String, arguments: [String: String], result: ToolResult) async {
        guard let id = arguments["session_id"], let session = await sessionManager?.session(id),
              let check = arguments["check_id"] else { return }
        let fields = result.structuredContent?.objectValue ?? [:]
        let outcome: VerificationCoverage.Outcome = if tool.hasPrefix("assert_"), !result.isError,
                                                       fields["passed"] == .bool(true) {
            .passed
        } else if tool.hasPrefix("assert_"), fields["passed"] == .bool(false),
                  fields["failure_kind"] == .string("assertion_mismatch") {
            .failed
        } else {
            .blocked
        }
        let actionIndex = await session.actions.count - 1
        await session.recordVerification(
            id: check, outcome: outcome,
            reason: outcome == .passed ? "Explicit assertion passed" : String(result.content.prefix(400)),
            evidence: ["action:\(actionIndex):\(tool)"]
        )
    }

    func executeVerificationReport(arguments: [String: String]) async throws -> ToolResult {
        guard let id = arguments["session_id"], let report = await sessionManager?.report(for: id) else {
            throw ToolExecutionError(code: "session_not_found", message: "No report for this session.")
        }
        let coverage = report.verification ?? VerificationCoverage(checks: [])
        return try .success(
            "Verification \(coverage.status): \(coverage.completedChecks)/\(coverage.checks.count) checks completed.",
            structuredContent: .object([
                "session_id": .string(id), "status": .string(coverage.status),
                "checks": Value(coverage.checks), "completed_checks": .int(coverage.completedChecks),
                "required_checks": .int(coverage.checks.count), "metrics": Value(report.verificationMetrics),
                "evidence_source": .string(
                    "get_session_report actions; persisted report.json when recording is enabled"
                )
            ])
        )
    }
}

// swiftlint:enable multiline_arguments
