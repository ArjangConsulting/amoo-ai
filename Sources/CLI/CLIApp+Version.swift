import AmooCore
import Foundation

extension CLIApp {
    /// `amoo version`: the source version, commit, and build time identifying this binary.
    static func verboseVersion(_ info: AmooBuildInfo) -> String {
        let format = ISO8601DateFormatter()
        var lines = ["amoo \(info.version)"]
        if let commit = info.sourceCommit {
            lines.append("commit:  \(commit)\(info.sourceDirty == "true" ? " (uncommitted changes)" : "")")
        } else {
            lines.append("commit:  unknown (not a source build)")
        }
        if let fingerprint = info.sourceFingerprint, fingerprint != "unknown" {
            lines.append("source:  \(fingerprint) (compare with scripts/source-fingerprint.sh)")
        }
        if let built = info.binaryModifiedAt {
            lines.append("built:   \(format.string(from: built))")
        }
        if let path = info.executablePath {
            lines.append("binary:  \(path)")
        }
        return lines.joined(separator: "\n")
    }

    /// `amoo version --json`: this binary's identity under the subagent report's provenance keys, so a
    /// report copies `host_binary`, `host_version` and `host_sha256` instead of describing them.
    static func versionJSON(_ info: AmooBuildInfo) -> String {
        var fields: [String: String] = [
            "host_version": info.version + (info.sourceCommit.map { " (\($0))" } ?? ""),
            "host_binary": info.executablePath ?? "unknown",
            "host_sha256": info.binarySHA256 ?? "unknown"
        ]
        if let commit = info.sourceCommit {
            fields["host_commit"] = commit
        }
        if let fingerprint = info.sourceFingerprint, fingerprint != "unknown" {
            fields["host_source_fingerprint"] = fingerprint
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(fields)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
    }
}
