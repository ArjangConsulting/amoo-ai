import AmooCore
import Foundation

/// Validate compact JSON before a parent accepts a subagent's verdict.
func runAgentReportValidation(_ args: [String]) -> CLIResult {
    var flags = EnvFlagReader(args)
    let json = flags.take("--json")
    do {
        guard let path = try flags.value("--report") else {
            throw EnvCommandParseError.usage("validate-report requires --report <report.json>")
        }
        guard let runID = try flags.value("--run-id"), let rawChecks = try flags.value("--checks") else {
            throw EnvCommandParseError.usage("Acceptance requires --run-id and --checks from the caller")
        }
        let checks = rawChecks.isEmpty ? [] : rawChecks.split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        try flags.finish()
        let url = URL(fileURLWithPath: path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 65536 else { throw EnvCommandParseError.usage("Report exceeds 64 KiB") }
        let data = try Data(contentsOf: url)
        guard data.count <= 65536 else { throw EnvCommandParseError.usage("Report exceeds 64 KiB") }
        try validateAgentReportShape(data)
        let report = try JSONDecoder().decode(AgentRunReport.self, from: data)
        let errors = report.validationErrors(expectedRunID: runID, requestedChecks: checks)
        let output = json ? renderJSON(AgentReportValidation(ok: errors.isEmpty, runID: report.runID, errors: errors))
            : errors.isEmpty ? "Valid report: \(report.runID) (\(report.status))" : errors.joined(separator: "\n")
        return CLIResult(output: output, exitCode: errors.isEmpty ? 0 : 1)
    } catch {
        let message = "Report validation failed: \(error)"
        return CLIResult(
            output: json ? renderJSON(AgentReportValidation(ok: false, runID: nil, errors: [message]))
                : message,
            exitCode: 1
        )
    }
}

private struct AgentReportValidation: Encodable {
    let ok: Bool
    let runID: String?
    let errors: [String]
}

/// Reject extra transcript fields instead of silently discarding them during Codable decoding.
private func validateAgentReportShape(_ data: Data) throws {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw EnvCommandParseError.usage("Report must be a JSON object")
    }
    let keys: Set = [
        "schemaVersion",
        "runID",
        "status",
        "execution",
        "verdict",
        "cleanup",
        "summary",
        "provenance",
        "assertions",
        "coverage",
        "artifacts"
    ]
    guard Set(object.keys) == keys,
          let coverage = object["coverage"] as? [String: Any],
          Set(coverage.keys) == ["requested", "evaluated", "notEvaluated", "truncated"],
          let assertions = object["assertions"] as? [[String: Any]],
          assertions.allSatisfy({ Set($0.keys) == ["check", "outcome", "evidence"] }),
          let artifacts = object["artifacts"] as? [[String: Any]],
          artifacts.allSatisfy({ Set($0.keys) == ["path", "sha256", "runID", "checks"] }) else {
        throw EnvCommandParseError.usage("Unexpected or missing report fields; keep raw evidence in local artifacts")
    }
}
