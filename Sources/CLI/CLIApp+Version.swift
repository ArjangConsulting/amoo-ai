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
}
