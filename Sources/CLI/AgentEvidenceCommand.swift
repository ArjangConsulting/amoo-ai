// SwiftFormat compact wrapping conflicts with argument layout lint.
// swiftlint:disable multiline_arguments
import AmooCore
import Foundation

/// Emit one manifest entry for inclusion in a version 2 compact report.
func runAgentEvidenceCapture(_ args: [String]) -> CLIResult {
    var flags = EnvFlagReader(args)
    do {
        guard let path = try flags.value("--path"), let runID = try flags.value("--run-id"),
              let checks = try flags.value("--checks") else {
            throw EnvCommandParseError.usage("evidence requires --path, --run-id and --checks")
        }
        try flags.finish()
        let artifact = try AgentEvidenceArtifact.capture(
            path: path, runID: runID,
            checks: checks.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        )
        return CLIResult(output: renderJSON(artifact), exitCode: 0)
    } catch { return CLIResult(output: "Cannot seal evidence: \(error)", exitCode: 1) }
}

// swiftlint:enable multiline_arguments
