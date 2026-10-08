import Foundation

/// Content identity and declared task scope of one regular local evidence file.
/// Hashes detect changed evidence; they do not certify the semantics of an assertion.
public struct AgentEvidenceArtifact: Codable, Sendable {
    public let path: String
    public let sha256: String
    public let runID: String
    public let checks: [String]

    public init(path: String, sha256: String, runID: String, checks: [String]) {
        self.path = path
        self.sha256 = sha256
        self.runID = runID
        self.checks = checks
    }

    /// Seal a bounded, regular evidence file after writing its final contents.
    public static func capture(path: String, runID: String, checks: [String]) throws -> Self {
        guard path.hasPrefix("/"), UUID(uuidString: runID) != nil, !checks.isEmpty,
              Set(checks).count == checks.count, checks.allSatisfy({ !$0.isEmpty }),
              let hash = sha256Hex(ofRegularFile: path, maximumBytes: 128 * 1024 * 1024) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return Self(path: path, sha256: hash, runID: runID, checks: checks)
    }
}
